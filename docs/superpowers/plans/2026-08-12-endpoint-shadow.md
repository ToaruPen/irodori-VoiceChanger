# Endpoint Shadow Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure whether a fixed trailing-silence boundary can safely replace part of the Apple Speech final wait without synthesizing or playing partial text.

**Architecture:** A Core actor correlates content-free audio activity samples with ordinary `SpeechEvent` values and keeps candidate text only in memory until final comparison. Thin macOS adapters reduce each PCM buffer to a Boolean activity sample. One CLI option selects one silence duration per session so 300/500/700ms remain separate experiments.

**Tech Stack:** Swift 6.3, Swift Testing, Apple Speech, AVFAudio, existing JSONL telemetry and report pipeline.

---

## Task 1: Pure endpoint evaluator

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/EndpointShadow.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/EndpointShadowTests.swift`

- [x] Write failing tests for threshold crossing, no-partial candidates, candidate reset after final, and speech resumption.
- [x] Run the focused suite and confirm it fails because the endpoint types do not exist.
- [x] Implement the smallest actor that stores one in-memory candidate per utterance and emits deterministic outcomes.
- [x] Run the focused suite and keep it green while extracting shared bucketed prefix comparison from the existing stable-prefix evaluator.

## Task 2: Privacy-safe telemetry and reporting

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/Telemetry.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Report.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Reporting.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/TelemetryTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`

- [x] Write failing encode/decode and report tests for endpoint candidate, resumption, candidate-to-final latency, match, and coverage.
- [x] Run the focused suites and confirm the missing event/metric failures.
- [x] Add only the required event names, metrics, counts, and report summaries.
- [x] Run the focused suites and confirm no transcript-derived values beyond bucketed ratios are serialized.

## Task 3: PCM activity adapter

**Files:**
- Create: `Sources/IrodoriVoiceChangerMacOS/AudioActivity.swift`
- Modify: `Sources/IrodoriVoiceChangerMacOS/MicrophoneCapture.swift`
- Modify: `Sources/IrodoriVoiceChangerMacOS/AudioFileReplay.swift`
- Create: `Tests/IrodoriVoiceChangerMacOSTests/AudioActivityTests.swift`
- Modify: `Tests/IrodoriVoiceChangerMacOSTests/AudioFileReplayTests.swift`

- [x] Write failing tests for Float32 RMS classification, silence, duration, and replay observation without dropped frames.
- [x] Run the focused suites and confirm the missing adapter failures.
- [x] Implement fixed −45 dBFS classification and optional activity callbacks after format conversion.
- [x] Run the focused suites and verify flag-off replay behavior remains unchanged.

## Task 4: CLI composition

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Live.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`

- [x] Write failing parser tests for `--shadow-endpoint-ms`, its 100...3000ms boundary, and run/replay propagation.
- [x] Run focused tests and confirm the flag is rejected before implementation.
- [x] Add one optional integer value and wire one monitor to the audio and speech streams without changing final synthesis.
- [x] Run focused CLI and pipeline tests.

## Task 5: Controlled measurement

**Files:**
- Modify: `README.md`
- Modify: `docs/validation/2026-08-12-stable-prefix-shadow.md`

- [x] Run `just check` before external validation.
- [x] Create one repo-external WAV by appending three seconds of silence to the existing fixed WAV.
- [x] Replay the same WAV five times each at 300ms, 500ms, and 700ms without synthesis and record content-free reports.
- [x] Select only a condition supported by the fixed replay, then run repeated fixed-phrase microphone validation and a silence control.
- [x] Document observations, limitations, and the next safe boundary; do not enable endpoint commitment or candidate playback.
- [x] Run `just check` and `git diff --check` after documentation.

## Task 6: Review hardening

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/EndpointShadow.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Report.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Live.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Modify: `Sources/IrodoriVoiceChangerMacOS/MicrophoneCapture.swift`
- Modify: `Sources/IrodoriVoiceChangerMacOS/AudioFileReplay.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/EndpointShadowTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`

- [x] Add a failing delayed-telemetry test before isolating shadow processing from audio and final paths.
- [x] Enqueue activity and SpeechEvent values synchronously into one ordered shadow consumer.
- [x] Ignore input after monitor cancellation and mark unmatched endpoint candidates incomplete.
- [x] Complete replay synthesis/output preflight before constructing its eager audio stream.
- [x] Run synthesis-enabled fixed-WAV replay and confirm one endpoint comparison and one final playback completion.
- [x] Defer endpoint telemetry writes until after the final pipeline stops and preserve enqueue timestamps.
- [x] Bound queue/event memory and fail closed with an incomplete report on overflow.
- [x] Re-run the full local gate after the review fixes.

No commit is part of this plan because repository instructions require explicit user authorization.
