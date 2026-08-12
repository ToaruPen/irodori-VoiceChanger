# AGENTS.md

## Why

`irodori-VoiceChanger` is a macOS 26 low-latency speech-to-Irodori PoC. Apple Speech owns
on-device Japanese transcription, Irodori owns voice synthesis, and CoreAudio owns routing to a
selected output such as BlackHole. The project measures the minimum practical latency without
persisting speech content.

## What

- `Sources/IrodoriVoiceChangerCore/`: platform-neutral contracts, pipeline, wire parsing, WAV,
  configuration, and telemetry
- `Sources/IrodoriVoiceChangerMacOS/`: thin Apple Speech, AVFAudio, CoreAudio, and TCC adapters
- `Sources/IrodoriVoiceChangerCLI/`: commands and composition root
- `Tests/`: deterministic unit tests; live boundaries are opt-in
- `config/`: versioned non-secret example configuration and app bundle metadata
- `docs/superpowers/`: accepted designs and implementation plans

The accepted design in `docs/superpowers/specs/` is authoritative for product behavior.

## How

Use Swift 6.3 through Xcode 26 on macOS 26. Repository commands run through `just`:

- `just bootstrap`: install repository-only secret scanning tools
- `just format`: apply deterministic Swift formatting
- `just test`: run tests without microphone, network, TCC prompts, or audible output
- `just check`: run format, lint, strict build, coverage, secret scan, and app-bundle gates
- `just doctor`: inspect local Speech, Irodori, and CoreAudio readiness
- `just devices`: list selectable CoreAudio outputs
- `just run`: build the app bundle and start the foreground voice changer
- `just replay INPUT.wav`: run repeatable Apple Speech latency measurements
- `just report`: summarize content-free telemetry

Behavior changes use Red → Green → Refactor. Keep Apple framework adapters thin and put
deterministic logic in Core. Unknown configuration and wire fields fail closed. Never write
transcripts, input audio, generated audio, voice IDs, device identifiers, endpoints, credentials,
or remote response bodies to telemetry. Live commands must not restart, redeploy, or reconfigure
Irodori.

Commit only when the user explicitly asks.
