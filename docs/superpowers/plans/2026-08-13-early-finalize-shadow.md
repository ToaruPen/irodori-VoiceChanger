# Early Finalize Shadow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a replay-only endpoint candidate handler that asks Apple Speech to finalize consumed audio early and measures the result without synthesis or playback.

**Architecture:** Reuse `EndpointShadowEvaluator` as the only silence/candidate owner. An optional Core handler records content-free request telemetry and invokes a closure; replay supplies a closure backed by `SpeechAnalyzer.finalize(through: nil)`. The default endpoint shadow and all live paths remain unchanged.

**Tech Stack:** Swift 6.3, Swift Testing, Speech.framework on macOS 26, existing JSONL telemetry and report builder.

---

## Task 1: Replay-only CLI contract

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Test: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`

- [ ] **Step 1: Write failing parser tests**

Add a documented parse case for:

```swift
.replay(
    input: "/tmp/input.wav",
    path: nil,
    synthesize: false,
    liveOutput: false,
    shadowSynthesizePrefix: false,
    endpointShadowMilliseconds: nil,
    earlyFinalizeShadowMilliseconds: 300
)
```

Add rejection cases combining `--shadow-early-finalize-ms` with synthesis, live output,
prefix synthesis, or `--shadow-endpoint-ms`, plus the existing 100...3,000 bound checks.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter CLITests`

Expected: compile failure because `earlyFinalizeShadowMilliseconds` and the option do not exist.

- [ ] **Step 3: Implement the minimal parser and option plumbing**

Add the optional value to `CLICommand.replay` and `ReplayOptions`, parse it with the same
bounded integer helper used for endpoint shadow, and fail closed on every prohibited combination.
Update only the replay usage line; do not add the option to `run`.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter CLITests`

Expected: all CLI tests pass.

## Task 2: Endpoint candidate handler

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/EndpointShadow.swift`
- Test: `Tests/IrodoriVoiceChangerCoreTests/EndpointShadowTests.swift`

- [ ] **Step 1: Write failing handler tests**

Define the wished-for contract in tests:

```swift
public protocol EndpointCandidateHandling: Sendable {
    func handleEndpointCandidate(utteranceID: UUID) async
}
```

Assert that a monitor with a handler invokes it once after a partial plus the threshold,
does not invoke it without a partial, and does not invoke it again during the same silence.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter EndpointShadowTests`

Expected: compile failure because the handler protocol and initializer parameter are missing.

- [ ] **Step 3: Implement the minimal optional callback**

Store an optional handler in `EndpointShadowMonitor`. After recording
`.candidate(candidatePresent: true)`, await the handler with the existing utterance ID. Do not
expose candidate text and do not call the handler for missing candidates, resumptions, or final
comparisons.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter EndpointShadowTests`

Expected: all endpoint shadow tests pass.

## Task 3: Measured finalization handler and report evidence

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/EndpointFinalization.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Telemetry.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Report.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Reporting.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/EndpointFinalizationTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`

- [ ] **Step 1: Write failing success and failure tests**

Exercise an `EndpointFinalizationHandler` initialized with a session ID, telemetry recorder,
clock, and `@Sendable () async throws -> Void`. Success must emit requested then completed with
duration and preserve the utterance ID. Failure must emit requested then failed with
`.speechUnavailable` and expose that stable failure without throwing across the queue boundary.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter EndpointFinalizationTests`

Expected: compile failure because the handler and telemetry events do not exist.

- [ ] **Step 3: Implement the minimal actor and telemetry names**

Add only:

```swift
case shadowEndpointFinalizeRequested
case shadowEndpointFinalizeCompleted
case shadowEndpointFinalizeFailed
```

The handler invokes the operation once per callback, measures completion with the injected clock,
records no content, and retains the first `.speechUnavailable` failure.

- [ ] **Step 4: Add report RED then GREEN**

First add a report test expecting request/completion/failure counts and
`endpoint_finalize_duration_ms`. Verify it fails, then add the three count fields and one latency
metric to `TelemetryReportBuilder` and CLI report output.

- [ ] **Step 5: Verify GREEN**

Run: `swift test --filter EndpointFinalizationTests && swift test --filter ReportTests`

Expected: both suites pass.

## Task 4: Apple adapter and replay composition

**Files:**
- Modify: `Sources/IrodoriVoiceChangerMacOS/AppleSpeechSession.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Test: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`

- [ ] **Step 1: Add the adapter required by the already-red composition build**

Expose one actor method:

```swift
public func finalizeConsumedAudio() async throws {
    try await analyzer.finalize(through: nil)
}
```

No other analyzer lifecycle method changes.

- [ ] **Step 2: Wire only the explicit replay option**

When `earlyFinalizeShadowMilliseconds` is present, build
`EndpointFinalizationHandler(operation: { try await speech.finalizeConsumedAudio() })`, pass it to
the implied endpoint monitor, and check its stored failure after the queue drains. Do not create the
handler for normal replay, live input, synthesis, or playback.

- [ ] **Step 3: Verify the narrow and full test suites**

Run: `swift test --filter CLITests && swift test`

Expected: all tests pass without Apple assets, microphone, network, or audible output.

## Task 5: Documentation and fixed-WAV experiment

**Files:**
- Modify: `README.md`
- Create: `docs/validation/2026-08-13-early-finalize-shadow.md`

- [ ] **Step 1: Document the opt-in safety boundary**

Document that the option is replay-only, speech-only, content-free, and does not validate semantic
chunk safety or activate Pipecat/Irodori.

- [ ] **Step 2: Run repository checks before live framework replay**

Run: `just format && just check`

Expected: format, lint, warnings-as-errors build, coverage, secret scan, justfile, and app bundle
gates all pass.

- [ ] **Step 3: Run one-variable replay measurements**

For each of 300, 500, and 700 ms, replay the fixed end WAV and six internal-pause WAVs without
`--synthesize` or `--live-output`. Summarize each session with `just report SESSION --json`.

- [ ] **Step 4: Record the evidence and stop condition**

Record aggregate counts and timings only. Stop without Pipecat integration if finalize fails to
return, candidate/final match regresses, or the lead is not material. Even on success, keep active
use disabled and recommend only the next semantic-boundary shadow experiment.

## Task 6: Scope and privacy audit

**Files:**
- Verify only; no new source files.

- [ ] **Step 1: Scan repeated identifiers and persisted artifacts**

Run `rg` for every new event/option identifier, `git diff --check`, and scan telemetry/validation for
transcripts, WAV paths, hashes, voice IDs, device IDs, endpoints, or response bodies.

- [ ] **Step 2: Verify repository boundaries**

Confirm the original VoiceChanger clone and `irodori-tts-infra` worktree were not modified. Do not
commit, push, synthesize, or play audio unless the user separately requests it.
