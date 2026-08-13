# Early finalize shadow design

## Goal

Measure whether an endpoint candidate delivered before Apple Speech's normal end
decision can reduce the roughly 2.1-second live finalization wait. This experiment
tests Apple `SpeechAnalyzer.finalize(through:)`, not Pipecat quality.

## Scope

- Replay only.
- Speech-only: no Irodori request, playback, or microphone output.
- Fixed WAVs and one silence threshold per run.
- Existing final-only behavior remains the default.
- No transcript, audio, text hash, voice, device, or endpoint is persisted.

Pipecat integration, semantic-completeness classification, speculative synthesis,
and active playback are out of scope. They are allowed only after this experiment
shows a material finalization lead without transcript regression.

## Interface

Add `--shadow-early-finalize-ms N` to `replay`. The value uses the existing endpoint
range of 100 through 3,000 milliseconds. The option is valid only without
`--synthesize`, `--live-output`, `--shadow-synthesize-prefix`, or
`--shadow-endpoint-ms`; it implies endpoint shadow at the same threshold.

The normal replay command and all live commands are unchanged.

## Data flow

1. `AudioFileReplay` continues feeding the same paced `AnalyzerInput` stream.
2. The existing audio activity observer sends speech/silence durations to
   `EndpointShadowQueue`.
3. `EndpointShadowMonitor` emits its first candidate only when an active utterance
   has a non-empty Apple partial.
4. An optional candidate handler calls `SpeechAnalyzer.finalize(through: nil)`.
   Per Apple's contract, `nil` finalizes through the last audio the analyzer has
   consumed while leaving analysis active for later input.
5. Existing mapper behavior starts a new utterance if speech continues after the
   finalized range.
6. Existing endpoint telemetry compares the candidate partial with the resulting
   final and records later speech resumption.

The handler records content-free requested/completed/failed events. A failure makes
the replay fail at the speech stage rather than silently falling back.

## Evaluation

Run the same seven WAVs used by the endpoint experiment at 300, 500, and 700 ms, one
threshold per replay. Compare with the existing unforced baseline using:

- endpoint candidate to final delivery;
- Apple audio-end to final delivery;
- candidate/final match and coverage;
- finalization request completion and failures;
- number of finalized chunks and speech resumptions.

The experiment passes the mechanical gate only if forced finalization returns,
publishes final results materially earlier than the roughly 2.1-second live baseline,
and does not reduce candidate/final match on the fixed corpus. Passing does not enable
active use. It only authorizes the next semantic-boundary shadow experiment.

## Tests and failure behavior

- TDD covers CLI validation, candidate-handler invocation, missing-partial suppression,
  single invocation per candidate, success/failure telemetry, and report aggregation.
- Existing default and endpoint-shadow tests remain unchanged.
- Queue overflow and finalization failure fail closed and never activate synthesis.
