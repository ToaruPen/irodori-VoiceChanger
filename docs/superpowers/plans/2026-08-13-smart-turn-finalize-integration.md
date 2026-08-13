# Smart Turn semantic finalize integration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Pipecat Smart Turn v3.2 natively in the macOS app and evaluate endpoint decisions with fixed-WAV replay and non-mutating live shadow.

**Architecture:** A new macOS-only Smart Turn target owns the bundled ONNX model, Pipecat-compatible feature extraction and one ONNX Runtime session. Core owns an ordered semantic endpoint handler, retry-after-resumption state and content-free telemetry. Replay and live record decisions only, leaving the existing Apple final/Irodori/playback path unchanged.

**Tech Stack:** Swift 6.3, Accelerate, AVFAudio, Microsoft ONNX Runtime 1.24.2 SPM package, Swift Testing, Speech.framework.

---

### Task 1: Package and model boundary

**Files:**
- Modify: `Package.swift`
- Modify: `scripts/build-app.sh`
- Create: `Sources/IrodoriVoiceChangerSmartTurn/Resources/smart-turn-v3.2-cpu.onnx`
- Create: `Sources/IrodoriVoiceChangerSmartTurn/Resources/PIPECAT-LICENSE.txt`
- Create: `Sources/IrodoriVoiceChangerSmartTurn/SmartTurnPrediction.swift`
- Create: `Tests/IrodoriVoiceChangerSmartTurnTests/SmartTurnPredictionTests.swift`

- [ ] Write a failing test that imports `IrodoriVoiceChangerSmartTurn`, constructs a bounded `SmartTurnPrediction`, and rejects non-finite or out-of-range probabilities.
- [ ] Run `swift test --filter SmartTurnPredictionTests` and confirm RED because the target and type do not exist.
- [ ] Add the official ONNX Runtime package pinned to `1.24.2`, a `IrodoriVoiceChangerSmartTurn` target depending on Core and `onnxruntime`, model/license resources, and its test target.
- [ ] Copy the model and BSD notice into the release app's `Contents/Resources`, and resolve resources from `Bundle.module` in package tests or `Bundle.main` in the app. Add a build-app assertion that both files exist.
- [ ] Implement only the validated prediction value and stable Smart Turn error enum needed by the test.
- [ ] Run the narrow test and confirm GREEN.

### Task 2: Pipecat-compatible feature extraction

**Files:**
- Create: `Sources/IrodoriVoiceChangerSmartTurn/SmartTurnFeatureExtractor.swift`
- Create: `Tests/IrodoriVoiceChangerSmartTurnTests/SmartTurnFeatureExtractorTests.swift`

- [ ] Generate privacy-safe Python oracle values for zero, impulse and deterministic sine inputs using Pipecat 1.7.0's `_whisper_features.py`; store only selected numeric feature cells and aggregate bounds in the test.
- [ ] Write failing tests for leading zero padding/trailing truncation to 128,000 samples, `(80, 800)` output shape, finite values and oracle parity.
- [ ] Run `swift test --filter SmartTurnFeatureExtractorTests` and confirm RED because the extractor is missing.
- [ ] Implement waveform normalization, periodic Hann window, centered reflect padding, 400-point real DFT using Accelerate, Slaney-normalized 80-bin mel projection, log clipping and Float32 output.
- [ ] Add one-shot AVAudioConverter resampling for non-16-kHz mono input, retaining the last eight seconds before feature extraction.
- [ ] Run the feature tests and confirm GREEN; refactor only after parity passes.

### Task 3: Native ONNX inference parity

**Files:**
- Create: `Sources/IrodoriVoiceChangerSmartTurn/SmartTurnClassifier.swift`
- Create: `Tests/IrodoriVoiceChangerSmartTurnTests/SmartTurnClassifierTests.swift`

- [ ] Write a failing test that loads the bundled model, sends a deterministic 16-kHz input, and expects a finite scalar prediction plus content-independent timing.
- [ ] Add deterministic zero, sine, impulse and 48 kHz resampling cases containing expected Python decisions or probabilities. Keep the external public synthetic WAV corpus as saved validation evidence; no user recording enters the repository.
- [ ] Run `swift test --filter SmartTurnClassifierTests` and confirm RED because the classifier is missing.
- [ ] Implement one actor-isolated ORT environment/session with sequential execution, one intra-op thread, all graph optimizations, `input_features` shape `[1, 80, 800]`, and scalar `logits` output validation.
- [ ] Run the classifier tests and confirm native/Python decision parity. Stop if any decision differs; do not tune the threshold.

### Task 4: Retryable semantic endpoint handler

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/EndpointShadow.swift`
- Create: `Sources/IrodoriVoiceChangerCore/SemanticEndpoint.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/EndpointShadowTests.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/SemanticEndpointTests.swift`

- [ ] Write failing tests for ordered in-memory audio delivery, eight-second bounding, buffer clearing on final/cancel, and one candidate invocation per silence.
- [ ] Write failing tests showing both incomplete and complete decisions remain non-terminal, while speech resumption rearms one later candidate after an incomplete decision.
- [ ] Run the two narrow suites and confirm RED on the missing audio/lifecycle/disposition contracts.
- [ ] Extend the candidate handler with default no-op speech/audio observation and a returned retry disposition; keep existing handlers source-compatible through defaults where possible.
- [ ] Add a shadow-only `SemanticEndpointHandler` with an injected classifier and bounded in-memory audio.
- [ ] Rearm `EndpointShadowEvaluator` only after a retryable candidate is followed by speech. Do not retry in the same silence.
- [ ] Run the narrow suites and confirm GREEN.

### Task 5: Privacy-safe semantic telemetry and report

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCore/Telemetry.swift`
- Modify: `Sources/IrodoriVoiceChangerCore/Report.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Reporting.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/TelemetryTests.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`

- [ ] Write failing round-trip tests for requested/completed/failed semantic events with duration, coarse probability bucket and Boolean completion only.
- [ ] Write a failing report test for request/complete/incomplete/failure counts and semantic inference p50/p95.
- [ ] Run `swift test --filter TelemetryTests` and `swift test --filter ReportTests`; confirm RED on missing names and fields.
- [ ] Add the minimal event names, metrics and aggregation. A semantic failure or unmatched request makes evidence incomplete.
- [ ] Extend the existing content-absence tests to prohibit audio, transcript, text, feature, path, hash, voice, device and endpoint fields.
- [ ] Run both suites and confirm GREEN.

### Task 6: PCM observation and CLI composition

**Files:**
- Modify: `Sources/IrodoriVoiceChangerMacOS/AudioActivity.swift`
- Modify: `Tests/IrodoriVoiceChangerMacOSTests/AudioActivityTests.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Replay.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Live.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`

- [ ] Write failing audio tests that extract bounded mono Float32 PCM from interleaved Int16 and non-interleaved Float32 buffers while preserving existing speech/duration classification.
- [ ] Implement PCM extraction in `AudioActivitySample`; the samples remain in memory and are never part of telemetry.
- [ ] Write failing CLI tests for replay and run `--shadow-smart-turn`, mutual exclusion with all existing endpoint/finalize/shadow-synthesis options, and unchanged defaults.
- [ ] Run the audio and CLI suites and confirm RED for the missing fields/options.
- [ ] Wire replay and live as shadow-only decisions with no downstream finalizer so existing Apple final/Irodori/playback behavior remains unchanged.
- [ ] Load the model before microphone or replay input consumption; fail closed if the resource/runtime is unavailable.
- [ ] Run the audio and CLI suites, then `swift test`, and confirm GREEN.

### Task 7: Fixed-WAV Gate 1 validation

**Files:**
- Modify: `README.md`
- Create: `docs/validation/2026-08-13-smart-turn-native-replay.md`

- [ ] Run `just format` followed by `just check`; stop on any failure.
- [ ] Replay the true-end WAV, six meaning-complete pause variants and three meaning-incomplete variants with `--shadow-smart-turn`, without synthesis or playback.
- [ ] Compare every native decision with the pinned Python oracle at threshold 0.5. Do not sweep thresholds.
- [ ] Verify meaning-incomplete pauses remain incomplete, while true ends and meaning-complete boundaries are classified complete.
- [ ] Aggregate semantic inference, decision counts, later speech resumption, failures, input drops and incomplete evidence.
- [ ] Record privacy-safe results and the Gate 1 pass/fail decision. Continue only on pass.

### Task 8: Live Gate 2 validation

**Files:**
- Modify: `docs/validation/2026-08-13-smart-turn-native-replay.md`

- [ ] Run `just run --shadow-smart-turn` and wait for `ready`.
- [ ] Ask the user to speak ordinary complete turns followed by deliberate meaning-incomplete pauses; do not display or persist transcripts.
- [ ] Stop cleanly, summarize the telemetry and compare with the live baseline.
- [ ] Record complete/incomplete decisions, resumption, inference p50/p95, input drops, failures and end-to-end lead.
- [ ] If Gate 2 fails, keep live semantic finalize unavailable and report the blocking evidence.

### Task 9: Reject the active connection after Gate 2

**Files:**
- Modify: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Modify: `Sources/IrodoriVoiceChangerCLI/Live.swift`
- Modify: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`
- Modify: `README.md`

- [ ] Record the failed Gate 2 evidence and the temporary supervised timing experiment.
- [ ] Remove semantic-to-finalizer wiring and reject the obsolete `--smart-turn-finalize` option for replay and live.
- [ ] Keep `--shadow-smart-turn` non-mutating and preserve the default final-only path.
- [ ] Run narrow tests and full `just check`.

### Task 10: Final audit

**Files:**
- Verify only.

- [ ] Run `just check`, PoC `uv run pytest -q`, `uv run ruff check .`, and `uv run ruff format --check .`.
- [ ] Run `git diff --check` and identifier scans for all new options/events.
- [ ] Verify no telemetry/result contains speech content, audio, features, paths, hashes, voice IDs, device IDs or endpoints.
- [ ] Verify `/Users/sankenbisha/Dev/irodori-VoiceChanger` and the `irodori-tts-infra` worktree remain unchanged.
- [ ] Preserve `codex/stable-prefix-shadow` without commit or push unless explicitly requested.
