# Stable Partial Prefix Shadow PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure whether stable Apple Speech partial prefixes can precede final results without changing synthesis or playback behavior.

**Architecture:** Add one deterministic core evaluator and a small telemetry monitor shared by synthesized and speech-only replay paths. Existing final-only commit, Irodori, and playback actors remain unchanged; `stable_prefix` only enables shadow observations.

**Tech Stack:** Swift 6.3, Swift Testing, Speech.framework, existing JSONL telemetry and replay commands.

---

No commits are created because the repository contract requires explicit user authorization.

### Task 1: Deterministic stable-prefix evaluator and configuration gate

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/StablePrefixShadow.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/StablePrefixShadowTests.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Configuration.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ConfigurationTests.swift`

- [x] **Step 1: Write failing evaluator tests**

Cover no candidate before both thresholds, append-only growth, suffix rewrite, rollback inside an
observed candidate, and final comparison without exposing text in outcomes.

```swift
var evaluator = StablePrefixShadowEvaluator(minimumObservations: 2, minimumStableNanoseconds: 100)
#expect(evaluator.observePartial("こん", at: 0).isEmpty)
#expect(evaluator.observePartial("こんに", at: 100).contains(.candidateAdvanced))
```

- [x] **Step 2: Verify RED**

Run: `swift test --filter StablePrefixShadowTests`
Expected: compilation fails because `StablePrefixShadowEvaluator` does not exist.

- [x] **Step 3: Implement the smallest evaluator**

Use `[Character]`, longest-common-prefix comparison, per-position consecutive observation counts,
and monotonic timestamps. Outcomes contain only event kinds and bounded comparison ratios.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter StablePrefixShadowTests`
Expected: all evaluator tests pass.

- [x] **Step 5: Activate only the shadow configuration**

Change configuration validation from `mode == .finalOnly` to accepting `.finalOnly` and
`.stablePrefix`. Replace the old fail-closed test with one asserting that the existing thresholds
decode unchanged in stable-prefix shadow mode.

- [x] **Step 6: Verify configuration tests**

Run: `swift test --filter ConfigurationTests`
Expected: all configuration tests pass, including strict threshold bounds.

### Task 2: Privacy-safe telemetry, report, and pipeline/replay wiring

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/StablePrefixShadow.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Telemetry.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Report.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Pipeline.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Reporting.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/TelemetryTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/PipelineTests.swift`

- [x] **Step 1: Write failing privacy and report tests**

Add typed shadow events and metrics, then assert encoded JSON contains ratios and booleans but no
candidate/final text, length, hash, path, URL, voice, or device fields. Add report fixtures for:

```text
speech_started -> shadow_prefix_candidate -> shadow_prefix_rewrite
-> shadow_prefix_rollback -> shadow_final_comparison -> asr_final
```

Assert candidate counts, rewrite/rollback counts, speech-start-to-candidate latency,
candidate-to-final lead, match ratio, and coverage ratio.

- [x] **Step 2: Verify RED**

Run: `swift test --filter 'TelemetryTests|ReportTests'`
Expected: compilation fails because shadow telemetry cases and report fields do not exist.

- [x] **Step 3: Implement the monitor and report aggregation**

`StablePrefixShadowMonitor.observe(_:)` owns evaluator state by utterance ID and records only the
four shadow event types. `TelemetryReportBuilder` aggregates the first candidate timestamp per
utterance and bounded final comparison ratios.

- [x] **Step 4: Verify telemetry and report GREEN**

Run: `swift test --filter 'StablePrefixShadowTests|TelemetryTests|ReportTests'`
Expected: all selected tests pass and JSON remains content-free.

- [x] **Step 5: Write a failing pipeline invariant test**

Construct a stable-prefix monitor, send enough partial events to create a candidate, and assert the
fake synthesizer has no texts and no `request_started` event before final. After final, assert exactly
one synthesis request containing only final text.

- [x] **Step 6: Verify pipeline RED, wire monitor, and verify GREEN**

Run before wiring: `swift test --filter PipelineTests`
Expected: the new invariant test fails because the pipeline does not observe shadow events.

Pass an optional concrete monitor into `VoiceChangerPipeline`. In speech-only replay call the same
monitor before `recordSpeechOnly`; in synthesized replay and live mode pass it to the pipeline.

Run after wiring: `swift test --filter 'PipelineTests|CLITests'`
Expected: all selected tests pass; partials emit shadow telemetry but never synthesize.

### Task 3: Replay evidence and the next single-variable decision

**Files:**
- Modify: `README.md`
- Create: `docs/validation/2026-08-12-stable-prefix-shadow.md`

- [x] **Step 1: Run deterministic local gates**

Run the narrow tests, then `just format && just check` and `git diff --check`.
Expected: format, lint, warnings-as-errors build, coverage, tests, secret scan, justfile check, and
app signature all pass.

- [x] **Step 2: Prepare two ephemeral configs and one fixed WAV**

Keep every field identical. The control uses `final_only`; the experiment changes only
`speech.commit_policy.mode` to `stable_prefix`. Generated WAV and configs remain outside the repo.

- [x] **Step 3: Replay control and shadow conditions repeatedly**

Run the same WAV for cold/warm observations without synthesis first. Record only session IDs and
content-free reports. Then run one `--synthesize` replay to prove final-only Irodori behavior remains
operational; do not use `--live-output` unless the configured loopback device passes preflight.

- [x] **Step 4: Make one evidence-based follow-up change**

If candidates are absent, change only `minimum_stable_milliseconds`; if candidates exist but appear
too late, change only one threshold; if rollback or mismatch is observed, do not relax thresholds.
Repeat the identical WAV and document the before/after distribution. Do not implement speculative
synthesis in this plan.

- [x] **Step 5: Document and verify the practical boundary**

Update README with shadow-mode semantics and write the validation record with environment,
conditions, min/p50/p95/max, rewrite/rollback, failures, drops, and the next-step decision. Re-run
`just check` after documentation changes.
