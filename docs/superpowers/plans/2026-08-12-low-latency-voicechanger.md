# Irodori VoiceChanger Low-Latency PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a telemetry-first macOS 26 voice changer PoC that continuously transcribes Japanese speech with Apple Speech, synthesizes finalized utterances through Irodori, and plays them on a selected CoreAudio output device.

**Architecture:** A Swift 6 single-process runtime separates deterministic core actors from thin Apple Speech, AVFAudio, and CoreAudio adapters. Every boundary emits content-free, monotonic telemetry, and both live microphone input and repeatable WAV replay feed the same pipeline.

**Tech Stack:** Swift 6.3, Swift Package Manager, Swift Testing, Speech.framework, AVFAudio, CoreAudio, URLSession AsyncBytes, the bundled `swift format` tool, SwiftLint, llvm-cov, just, secretlint.

---

## File map

- `Package.swift`: Swift package products, targets, strict compiler settings.
- `Sources/IrodoriVoiceChangerCore/Models.swift`: utterance, speech, audio, and stable error types.
- `Sources/IrodoriVoiceChangerCore/Clock.swift`: production and deterministic monotonic clocks.
- `Sources/IrodoriVoiceChangerCore/Telemetry.swift`: typed events, bounded JSONL recorder, aggregation.
- `Sources/IrodoriVoiceChangerCore/Configuration.swift`: strict versioned JSON configuration.
- `Sources/IrodoriVoiceChangerCore/IrodoriWire.swift`: public Irodori request/capability/frame models and parser.
- `Sources/IrodoriVoiceChangerCore/IrodoriClient.swift`: HTTP health, capability, and streamed synthesis.
- `Sources/IrodoriVoiceChangerCore/Pipeline.swift`: commit, synthesis, playback queue, and backpressure actors.
- `Sources/IrodoriVoiceChangerMacOS/AppleSpeechSession.swift`: SpeechAnalyzer integration and replay.
- `Sources/IrodoriVoiceChangerMacOS/MicrophoneCapture.swift`: AVAudioEngine input bridge.
- `Sources/IrodoriVoiceChangerMacOS/CoreAudioDevices.swift`: output device enumeration and UID resolution.
- `Sources/IrodoriVoiceChangerMacOS/CoreAudioPlayer.swift`: selected-device AVAudioEngine playback.
- `Sources/IrodoriVoiceChangerMacOS/Permissions.swift`: microphone and speech authorization.
- `Sources/IrodoriVoiceChangerCLI/CLI.swift`: strict commands, output, and exit codes.
- `Sources/IrodoriVoiceChangerCLI/main.swift`: composition root only.
- `Tests/IrodoriVoiceChangerCoreTests/`: deterministic core and HTTP contract tests.
- `Tests/IrodoriVoiceChangerMacOSTests/`: adapter contract tests without requesting TCC access.
- `config/Info.plist`: stable bundle identity and privacy usage descriptions.
- `config/irodori-voicechanger.example.json`: complete non-secret configuration.
- `scripts/build-app.sh`: reproducible `.app` bundle assembly and ad-hoc signing.
- `scripts/coverage.sh`: core line-coverage gate.
- `justfile`: canonical developer and operator commands.
- `AGENTS.md`, `README.md`, `SECURITY.md`: repository contract and operator guidance.

No commits are created during this run because the user has not explicitly authorized commits.

**Implementation status (2026-08-12):** Tasks 1–10 are implemented and verified. Real Irodori
synthesis, BlackHole playback, sustained microphone input, Discord input routing, and the first
one-variable latency experiments are recorded in
`docs/validation/2026-08-12-initial-baseline.md`.

### Task 1: Repository and deterministic toolchain

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `.swift-format`
- Create: `.swiftlint.yml`
- Create: `.secretlintrc.json`
- Create: `package.json`
- Create: `justfile`
- Create: `AGENTS.md`
- Create: `LICENSE`
- Create: `SECURITY.md`

- [x] **Step 1: Add package and empty target directories**

Create a macOS 26 package with library targets `IrodoriVoiceChangerCore` and
`IrodoriVoiceChangerMacOS`, plus executable target `IrodoriVoiceChangerCLI`. Enable Swift 6
language mode and warnings-as-errors through the `just build` command. Add only Apple system
frameworks; no runtime package dependency is needed.

- [x] **Step 2: Add repository gates**

Define these recipes exactly:

```make
format:
    swift format format --in-place --recursive Sources Tests Package.swift

format-check:
    swift format lint --strict --recursive Sources Tests Package.swift

lint:
    swiftlint lint --strict

build:
    swift build -Xswiftc -warnings-as-errors

test:
    swift test

test-cov:
    bash scripts/coverage.sh

secret-scan:
    npm exec -- secretlint .

check: format-check lint build test-cov secret-scan build-app
```

- [x] **Step 3: Validate instructions**

Run:

```bash
python3 ~/.codex/skills/agents-md-best-practices/scripts/agents_md_tool.py audit \
  --root "$PWD" --require-why-what-how
```

Expected: no errors and a root `AGENTS.md` under 300 lines.

### Task 2: Typed telemetry and bottleneck report

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/Clock.swift`
- Create: `Sources/IrodoriVoiceChangerCore/Models.swift`
- Create: `Sources/IrodoriVoiceChangerCore/Telemetry.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/TelemetryTests.swift`
- Create: `scripts/coverage.sh`

- [x] **Step 1: Write failing event privacy and correlation tests**

Tests construct `TelemetryEvent` values and assert encoded JSON contains only schema version,
session/utterance IDs, monotonic timestamp, event name, stage, stable error code, and typed scalar
metrics. Attempting to create metadata with transcript, URL, device, or free-form fields must be
impossible through the public initializer.

```swift
@Test func telemetryNeverEncodesContent() throws {
    let event = TelemetryEvent(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        utteranceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        timestampNanoseconds: 42,
        name: .requestCompleted,
        metrics: .init(durationMilliseconds: 123, byteCount: 456)
    )
    let json = String(decoding: try JSONEncoder.telemetry.encode(event), as: UTF8.self)
    #expect(json.contains("request_completed"))
    #expect(!json.contains("transcript"))
    #expect(!json.contains("http"))
}
```

- [x] **Step 2: Run RED**

Run: `swift test --filter TelemetryTests`

Expected: compile failure because telemetry types do not exist.

- [x] **Step 3: Implement clock, events, recorder, rotation, and report**

Use `DispatchTime.now().uptimeNanoseconds` behind `MonotonicClock`. Implement an actor-based
JSONL recorder that creates files with mode `0600`, rotates at configurable byte count, retains
three generations, and returns `.unavailable` instead of throwing into the audio pipeline.
Implement nearest-rank min/p50/p95/max aggregation for the design metrics.

- [x] **Step 4: Verify GREEN and coverage**

Run: `swift test --filter TelemetryTests && bash scripts/coverage.sh`

Expected: telemetry tests pass; the script reports core line coverage at least 90% or names the
uncovered core lines and exits nonzero.

### Task 3: Strict configuration and command parsing

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/Configuration.swift`
- Create: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/ConfigurationTests.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/CLITests.swift`
- Create: `config/irodori-voicechanger.example.json`

- [x] **Step 1: Write failing strict configuration tests**

Cover the complete valid example, unknown keys, invalid schema version, credential-bearing URL,
non-HTTPS non-loopback URL, missing output UID, sampling bounds, queue bounds, and telemetry
rotation bounds. Decode through a whitelist validation pass before `JSONDecoder` because Codable
normally ignores unknown keys.

- [x] **Step 2: Run RED**

Run: `swift test --filter ConfigurationTests`

Expected: compile failure because `AppConfiguration` does not exist.

- [x] **Step 3: Implement configuration and CLI grammar**

Support only:

```text
config init [--path PATH]
config validate [--path PATH]
doctor [--path PATH] [--synthesize]
devices
run [--path PATH] [--show-transcript]
replay INPUT.wav [--path PATH] [--synthesize] [--live-output]
report [SESSION|latest] [--path PATH] [--json]
```

Unknown commands/options and missing option values return usage error code 64 without side effects.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter 'ConfigurationTests|CLITests'`

Expected: all configuration and grammar tests pass.

### Task 4: Irodori capabilities and framed streaming client

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/IrodoriWire.swift`
- Create: `Sources/IrodoriVoiceChangerCore/IrodoriClient.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/IrodoriWireTests.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/IrodoriClientTests.swift`

- [x] **Step 1: Write failing wire parser tests**

Port the public version-1 framing invariants needed by the Swift client: exactly one handshake,
monotonic frame indices, bounded `nbytes`, exact payload length, known error codes, exactly one
terminal `final=true`, no frames after final, total byte limit, and frame count limit. Include a
valid stream split across every byte boundary.

- [x] **Step 2: Run RED**

Run: `swift test --filter IrodoriWireTests`

Expected: compile failure because `IrodoriStreamParser` does not exist.

- [x] **Step 3: Implement typed public models and parser**

Implement strict health, capabilities, voice, synthesis request, handshake, and chunk models.
Resolve configured canonical ID or unique alias; otherwise require exactly one default. Bind every
request to the resolved ID and capabilities generation. Expose stream milestones for handshake,
first audio, and completion without exposing response bodies in errors.

- [x] **Step 4: Test HTTP behavior with URLProtocol**

Use a custom `URLProtocol` fixture to cover readiness failure, generation mismatch, backpressure,
timeout normalization, successful async bytes, and cancellation. No test opens a network socket.

- [x] **Step 5: Verify GREEN**

Run: `swift test --filter 'IrodoriWireTests|IrodoriClientTests'`

Expected: all wire and client tests pass.

### Task 5: Telemetry-first pipeline and bounded queues

**Files:**
- Create: `Sources/IrodoriVoiceChangerCore/Pipeline.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/PipelineTests.swift`

- [x] **Step 1: Write failing end-to-end core tests**

With fake clock, speech source, synthesizer, and player, assert exact event order for one utterance:

```text
speech_started -> asr_partial -> speech_ended -> asr_final -> utterance_committed
-> request_started -> stream_handshake -> first_audio_payload -> request_completed
-> playback_enqueued -> playback_started -> playback_completed
```

Also cover two overlapping utterances, synthesis serialization, ordered playback, queue saturation,
three consecutive remote failures, generation change, player failure, and graceful stop.

- [x] **Step 2: Run RED**

Run: `swift test --filter PipelineTests`

Expected: compile failure because `VoiceChangerPipeline` does not exist.

- [x] **Step 3: Implement actors and protocols**

Define only `SpeechEventSource`, `Synthesizing`, `AudioPlaying`, `TelemetryRecording`, and
`MonotonicClock`. Keep final-only commit as the active default. Serialize synthesis with an actor,
bound pending synthesis/playback queues, preserve active playback, and emit explicit drop/failure
events instead of silent loss.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter PipelineTests`

Expected: all deterministic pipeline tests pass with no sleeps or wall-clock dependence.

### Task 6: Apple Speech live and replay adapters

**Files:**
- Create: `Sources/IrodoriVoiceChangerMacOS/AppleSpeechSession.swift`
- Create: `Sources/IrodoriVoiceChangerMacOS/MicrophoneCapture.swift`
- Create: `Sources/IrodoriVoiceChangerMacOS/Permissions.swift`
- Create: `Tests/IrodoriVoiceChangerMacOSTests/AppleSpeechMappingTests.swift`

- [x] **Step 1: Write failing pure mapping tests**

Extract result-to-domain mapping from framework lifecycle. Test partial/final classification,
range-to-utterance correlation, speech detected true/false transitions, empty result rejection,
and revision counting with synthetic adapter values.

- [x] **Step 2: Run RED**

Run: `swift test --filter AppleSpeechMappingTests`

Expected: compile failure because the mapping adapter does not exist.

- [x] **Step 3: Implement macOS 26 adapters**

Use `SpeechTranscriber(locale:preset:.progressiveTranscription)`, `SpeechDetector`,
`SpeechAnalyzer.bestAvailableAudioFormat`, `prepareToAnalyze`, and an `AsyncStream<AnalyzerInput>`.
The microphone tap copies buffers before leaving the realtime callback and uses bounded buffering;
the callback never awaits, logs, allocates JSON, or calls network code. Replay feeds `AVAudioFile`
through the same speech event mapping.

- [x] **Step 4: Verify build and non-live tests**

Run: `swift build -Xswiftc -warnings-as-errors && swift test --filter AppleSpeechMappingTests`

Expected: strict build and mapping tests pass without requesting microphone permission.

### Task 7: CoreAudio device routing and WAV playback

**Files:**
- Create: `Sources/IrodoriVoiceChangerMacOS/CoreAudioDevices.swift`
- Create: `Sources/IrodoriVoiceChangerMacOS/CoreAudioPlayer.swift`
- Create: `Sources/IrodoriVoiceChangerCore/WAV.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/WAVTests.swift`
- Create: `Tests/IrodoriVoiceChangerMacOSTests/CoreAudioDeviceTests.swift`

- [x] **Step 1: Write failing WAV and device selection tests**

Cover valid PCM WAV, truncated RIFF, unsupported encoding, duration calculation, 60-second bound,
64-MiB bound, unique UID selection, missing UID, zero-output-channel device, and no default fallback.

- [x] **Step 2: Run RED**

Run: `swift test --filter 'WAVTests|CoreAudioDeviceTests'`

Expected: compile failure because WAV and device catalog types do not exist.

- [x] **Step 3: Implement routing and playback**

Enumerate devices with `AudioObjectGetPropertyData`, resolve by UID, attach
`AVAudioPlayerNode` to `AVAudioEngine`, and set the selected `AudioDeviceID` using
`kAudioOutputUnitProperty_CurrentDevice`. Schedule validated WAV buffers and emit start/completion
callbacks from the player actor.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter 'WAVTests|CoreAudioDeviceTests' && swift build -Xswiftc -warnings-as-errors`

Expected: tests and strict build pass without producing sound.

### Task 8: CLI composition, app bundle, doctor, replay, and report

**Files:**
- Create: `Sources/IrodoriVoiceChangerCLI/main.swift`
- Create: `Sources/IrodoriVoiceChangerCLI/Composition.swift`
- Create: `config/Info.plist`
- Create: `scripts/build-app.sh`
- Modify: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/ReportTests.swift`
- Create: `Tests/IrodoriVoiceChangerCoreTests/DoctorTests.swift`

- [x] **Step 1: Write failing report and doctor tests**

Assert report nearest-rank percentiles, incomplete-session annotation, empty-session output, and
content-free JSON. Assert doctor stable checks for OS, config, locale, asset, microphone permission,
Irodori readiness, voice resolution, and output UID without exposing identifiers.

- [x] **Step 2: Run RED**

Run: `swift test --filter 'ReportTests|DoctorTests'`

Expected: failures because command handlers are not composed.

- [x] **Step 3: Implement commands and app assembly**

Build `IrodoriVoiceChanger.app` with bundle identifier `dev.toarupen.IrodoriVoiceChanger`,
`NSMicrophoneUsageDescription`, `LSUIElement=true`, and the
SwiftPM release executable. Ad-hoc sign with `codesign --force --sign -` and verify with
`codesign --verify --deep --strict`.

- [x] **Step 4: Verify GREEN and operator help**

Run:

```bash
swift test --filter 'ReportTests|DoctorTests'
just build-app
dist/IrodoriVoiceChanger.app/Contents/MacOS/irodori-voicechanger help
```

Expected: tests pass, signature verifies, and help lists only the documented commands.

### Task 9: Documentation, CI, and full local gate

**Files:**
- Create: `README.md`
- Create: `.github/workflows/ci.yml`
- Modify: `AGENTS.md`
- Modify: `justfile`

- [x] **Step 1: Document setup and privacy boundaries**

Document macOS 26/Xcode 26, `just bootstrap`, bundle permission flow, strict JSON configuration,
BlackHole output selection, Discord input selection, headphone monitoring, commands, telemetry
fields and omissions, replay comparison, troubleshooting, and explicit live-operation boundaries.

- [x] **Step 2: Add CI**

Use a macOS 26 runner only after validating the current GitHub-hosted runner label. Run npm install,
format lint, warnings-as-errors build, unit tests with coverage, secret scan, and app bundle build.
If GitHub does not publish a macOS 26 hosted label, make CI build the core target on the newest
published macOS runner and keep macOS 26 framework compilation as a documented local required gate.

- [x] **Step 3: Run full checks**

Run:

```bash
just format
just check
python3 ~/.codex/skills/agents-md-best-practices/scripts/agents_md_tool.py audit \
  --root "$PWD" --require-why-what-how
git status --short
```

Expected: all deterministic gates pass; status lists only intentional uncommitted project files.

### Task 10: Safe live verification and latency baseline

**Files:**
- Create: `docs/validation/2026-08-12-initial-baseline.md`

- [x] **Step 1: Run read-only doctor and enumerate outputs**

Run `just doctor` and `just devices`. Record only check codes, pass/fail, OS/tool versions, and
whether a selectable virtual output exists. Do not record hostnames, device UIDs, or voice IDs.

- [x] **Step 2: Request TCC permissions through the app bundle**

Launch the bundled foreground app and let macOS present microphone and speech recognition prompts.
If permission requires user interaction, report the exact prompt and continue all non-blocked
validation while waiting; never alter the TCC database directly.

- [x] **Step 3: Verify Irodori without operational changes**

Use current configured endpoint only. Run health/capabilities, then one fixed non-sensitive
synthesis through `doctor --synthesize`. Do not restart, redeploy, or modify Irodori without
separate authorization. The later user request for required setup authorized starting the existing
deployment, but not replacing its runtime or voice bank. Record
handshake, first-audio, complete, server elapsed, WAV duration, and RTF.

- [x] **Step 4: Verify selected output**

Send a bounded generated test tone, then the fixed synthesis to the selected non-default output.
Confirm routing with CoreAudio state and player completion. Discord application interaction requires
explicit setup authorization; when granted, select the device without persisting it to telemetry.

- [x] **Step 5: Measure replay and microphone baseline**

Run cold and warm external-WAV replay, then a short live microphone session. Produce content-free
min/p50/p95/max for each pipeline interval, partial revisions, queue depth, underrun, drop, and
failures. Mark any metric blocked by TCC, missing virtual device, or unavailable Irodori instead of
inventing results.

- [x] **Step 6: Identify the first optimization experiment**

Choose the largest measured interval. Change exactly one of Speech detector sensitivity, input
buffer size, commit policy, or Irodori sampling only when the prior quality evidence permits it.
Repeat the same replay input and update the validation document with before/after evidence.
