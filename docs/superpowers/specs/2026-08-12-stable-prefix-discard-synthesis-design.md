# Stable prefix discard-only synthesis design

## Goal

Measure the real Irodori latency and load of synthesizing the first stable prefix without storing or
playing candidate audio and without delaying or replacing final-only synthesis.

## Evidence and decision

The 3 observations / 400ms shadow rule produced a matching candidate for all four intentional live
microphone utterances. Candidates appeared 876–1005ms after speech start, matched the final prefix in
all four cases, and preceded final by 4.8–5.8 seconds. A following 20-second silence control produced
no utterance or request. This is enough evidence to test one additional stage, but not enough to play
candidate audio.

The experiment uses an explicit `--shadow-synthesize-prefix` CLI flag. `stable_prefix` without the flag
keeps its current telemetry-only behavior, and `final_only` rejects the flag. Replay additionally
requires `--synthesize`. No configuration default changes.

## Data flow

`StablePrefixShadowEvaluator` exposes its current candidate in memory. On the first candidate advance
for an utterance, `StablePrefixShadowMonitor` submits that text to one optional candidate handler. The
discarding handler starts at most one Irodori request per utterance. Returned WAV bytes exist only in
memory long enough to validate the existing `AudioClip`; they are neither persisted nor passed to an
`AudioPlaying` implementation.

When final arrives, the handler cancels an unfinished candidate request before the normal pipeline
accepts final. The normal final queue, request, playback, failure threshold, and restart behavior remain
unchanged. Candidate failure is recorded as shadow evidence and never triggers pipeline restart or
drops the final utterance. Pipeline stop waits for candidate work; pipeline cancel cancels it.

## Telemetry and privacy

Candidate synthesis uses distinct `shadow_synthesis_*` events for start, handshake, first audio,
completion, cancellation, failure, and first-candidate/final comparison. The report shows request
counts and request-to-handshake, request-to-first-audio, request-to-complete, server elapsed, and
bucketed first-candidate match/coverage.

Telemetry may contain durations, sampling steps, byte counts, and the existing stable error code. It
must not contain partial/final text, character counts, hashes, audio, paths, endpoint, voice, or device
identifiers. Match and coverage remain rounded to 0.1.

## Safety invariants

- One candidate request at most per utterance; later candidate advances do not synthesize again.
- Candidate audio is never enqueued, played, cached, or written.
- Final synthesis still occurs exactly once with the complete final text.
- Candidate cancellation or failure cannot fail or restart the final pipeline.
- The feature is opt-in and valid only with `stable_prefix`.
- Existing `stable_prefix` and `final_only` behavior remains unchanged without the flag.

## Verification

TDD fixes the one-request rule, no-playback rule, final-priority cancellation, failure isolation,
privacy-safe JSON, report aggregation, and CLI gating. After the full local gate passes, the same fixed
WAV is replayed five times with only the new flag changed. Live microphone validation follows only if
candidate requests finish before final without worsening final request or playback metrics. No
candidate audio is played in either validation.
