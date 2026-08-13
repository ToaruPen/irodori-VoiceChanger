# Stable Prefix Discard-Only Synthesis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send the first stable prefix to Irodori once, discard its audio, and measure latency without changing final synthesis or playback.

**Architecture:** Extend the existing stable-prefix monitor with an optional candidate handler. A focused actor owns one discard-only request per utterance, cancels unfinished work at final, emits separate privacy-safe telemetry, and never reaches the playback queue. CLI flags opt replay or live execution into the experiment.

**Tech Stack:** Swift 6.3, Swift Testing, existing `Synthesizing` protocol, JSONL telemetry, Apple Speech replay/live paths.

---

Repository policy requires explicit authorization for commits. The user authorized autonomous
implementation but did not request commits, so commit steps are intentionally omitted.

### Task 1: Candidate contract and first-candidate selection

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/StablePrefixShadow.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/StablePrefixShadowTests.swift`

- [x] **Step 1: Write failing evaluator and monitor tests**

Add a test that observes two equal partials and expects `evaluator.candidateText == "こん"`. Add a
`StablePrefixCandidateHandling` spy, advance the candidate twice, and assert it receives only the first
candidate. Final must be forwarded once, and stop/cancel must delegate to the handler.

- [x] **Step 2: Run RED**

Run: `swift test --filter StablePrefixShadowTests`

Expected: compilation fails because `candidateText`, `StablePrefixCandidateHandling`, and the optional
handler initializer argument do not exist.

- [x] **Step 3: Add the minimal contract**

Add this protocol and evaluator property:

```swift
public protocol StablePrefixCandidateHandling: Sendable {
    func submit(candidate: String, utteranceID: UUID) async
    func finish(final: String, utteranceID: UUID) async
    func stop() async
    func cancel() async
}

public var candidateText: String? {
    guard candidateLength > 0 else { return nil }
    return String(previousPartial.prefix(candidateLength))
}
```

Give `StablePrefixShadowMonitor` an optional handler. Submit only when `.candidateAdvanced` is emitted;
the handler owns de-duplication. Forward final, stop, and cancel without logging text.

- [x] **Step 4: Run GREEN**

Run: `swift test --filter StablePrefixShadowTests`

Expected: all stable-prefix evaluator and monitor tests pass.

### Task 2: Discard-only synthesis actor

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/StablePrefixShadowSynthesis.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/StablePrefixShadowSynthesisTests.swift`

- [x] **Step 1: Write failing actor tests**

Using a recording `Synthesizing` test actor, assert:

```swift
await subject.submit(candidate: "こん", utteranceID: id)
await subject.submit(candidate: "こんにちは", utteranceID: id)
await subject.stop()
#expect(await synthesizer.texts == ["こん"])
#expect(events contain start, first-audio, and completion exactly once)
```

Add focused tests that an unfinished task is cancelled by `finish`, a thrown candidate request records
shadow failure but does not throw, and the first candidate is compared with final using 0.1-bucketed
ratios. Assert no `playback_*`, normal `request_*`, text, length, hash, path, URL, voice, or device field
appears in encoded telemetry.

- [x] **Step 2: Run RED**

Run: `swift test --filter StablePrefixShadowSynthesisTests`

Expected: compilation fails because `DiscardingStablePrefixSynthesizer` and its event names do not
exist.

- [x] **Step 3: Implement the minimal actor**

Create:

```swift
public actor DiscardingStablePrefixSynthesizer: StablePrefixCandidateHandling {
    public init(
        sessionID: UUID,
        synthesizer: any Synthesizing,
        telemetry: any TelemetryRecording,
        clock: any MonotonicClock
    )
}
```

Store the first candidate in memory and start one `Task` per utterance. Emit dedicated shadow
milestones. Drop the returned `AudioClip` after recording bounded duration and byte-count metrics.
`finish` compares and removes candidate text, then cancels unfinished work without awaiting it. `stop`
awaits active tasks; `cancel` cancels and awaits them. Catch candidate errors inside the actor.

- [x] **Step 4: Run GREEN**

Run: `swift test --filter StablePrefixShadowSynthesisTests`

Expected: all one-request, cancellation, isolation, comparison, and privacy tests pass.

### Task 3: Dedicated report metrics

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/Telemetry.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Report.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Reporting.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/TelemetryTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`

- [x] **Step 1: Write failing report tests**

Build one event sequence containing shadow synthesis start, handshake, first audio, completion, and
first-candidate/final comparison. Assert distinct started/completed/cancelled/failure counts and metric
summaries for request-to-handshake, request-to-first-audio, request-to-complete, server elapsed,
candidate match, and candidate coverage. Normal request and playback counts must remain unchanged.

- [x] **Step 2: Run RED**

Run: `swift test --filter 'TelemetryTests|ReportTests'`

Expected: compilation fails on missing event, count, and metric cases.

- [x] **Step 3: Add typed events and aggregation**

Add `shadow_synthesis_started`, `shadow_synthesis_handshake`, `shadow_synthesis_first_audio`,
`shadow_synthesis_completed`, `shadow_synthesis_cancelled`, `shadow_synthesis_failed`, and
`shadow_synthesis_final_comparison`. Add matching report counts and latency metric names. Aggregate
only these dedicated events so normal pipeline metrics are not contaminated.

- [x] **Step 4: Run GREEN**

Run: `swift test --filter 'TelemetryTests|ReportTests'`

Expected: all telemetry encoding and report aggregation tests pass.

### Task 4: Opt-in CLI and pipeline lifecycle wiring

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/Pipeline.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/StablePrefixPipelineTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`

- [x] **Step 1: Write failing CLI and pipeline tests**

Assert parser results include `shadowSynthesizePrefix: true` for:

```text
run --shadow-synthesize-prefix
replay input.wav --synthesize --shadow-synthesize-prefix
```

Assert replay rejects the flag without `--synthesize`, and runtime gating rejects it for `final_only`.
In the pipeline test, make the shadow handler record cancellation and assert it is cancelled before the
normal final synthesizer sees the final text. Assert exactly one final playback.

- [x] **Step 2: Run RED**

Run: `swift test --filter 'CLITests|StablePrefixPipelineTests'`

Expected: compilation fails because the command fields, flag, runtime gate, and monitor lifecycle calls
do not exist.

- [x] **Step 3: Wire the opt-in experiment**

Add `shadowSynthesizePrefix: Bool` to run and replay command values. Accept
`--shadow-synthesize-prefix`, require replay `--synthesize`, and after loading configuration require
`speech.commit_policy.mode == stable_prefix`. Reuse the prepared final synthesizer to create
`DiscardingStablePrefixSynthesizer`, then inject it into the monitor. Call monitor stop/cancel from the
pipeline and speech-only boundaries. Do not pass candidate audio to the player.

- [x] **Step 4: Run GREEN**

Run: `swift test --filter 'CLITests|StablePrefixPipelineTests|StablePrefixShadowSynthesisTests'`

Expected: all focused tests pass, with one candidate request, one final request, and only final
playback.

### Task 5: Documentation, gates, and measurements

**Files:**
- Modify: `README.md`
- Modify: `docs/validation/2026-08-12-stable-prefix-shadow.md`

- [x] **Step 1: Document the opt-in boundary**

Document the new flag, partial-to-Irodori privacy boundary, one-request rule, discard-only audio, final
fallback, and absence of playback/storage.

- [x] **Step 2: Run deterministic gates**

Run: `swift format format --in-place --recursive Sources Tests Package.swift`

Run: `just check && git diff --check`

Expected: formatting, SwiftLint, warnings-as-errors build, all tests and coverage, secret scan,
justfile check, release app build/signature, and whitespace checks pass.

- [x] **Step 3: Replay one variable at a time**

Use the same fixed WAV and 3 observations / 400ms config. Run five control replays with `--synthesize`
and five experiment replays adding only `--shadow-synthesize-prefix`. Report candidate request
completion/cancellation/failure, request-to-first-audio, total/server time, final request latency,
playback timing, failures, and drops. Candidate audio remains discarded.

- [x] **Step 4: Gate live validation**

Proceed to one fixed-script microphone session only if replay candidate requests finish before final
and final metrics show no material regression. Keep candidate audio discarded. Follow with the same
silence control and document intentional versus extra ASR utterances separately.

- [x] **Step 5: Re-run final verification**

Run: `just check && git diff --check`

Expected: all gates pass after validation documentation changes.
