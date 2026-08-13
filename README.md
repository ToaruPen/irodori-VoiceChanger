# Irodori VoiceChanger

Irodori VoiceChanger is an experimental macOS application for turning Japanese microphone speech
into an Irodori-generated voice and routing the result to a selected CoreAudio output. It is also a
measurement harness for finding where conversational latency is actually spent: speech endpointing,
Apple Speech finalization, Irodori synthesis, transport, queueing, or playback.

> [!IMPORTANT]
> This repository is a proof of concept, not a production voice changer. The normal path sends only
> finalized Apple Speech results to Irodori. Experimental endpoint and partial-transcript features
> remain opt-in shadow measurements and do not alter audible output unless explicitly documented.

## Status

The final-only microphone-to-Irodori path works on macOS 26 and can route generated audio to a
loopback device such as BlackHole. Fixed-WAV replay, content-free telemetry, latency reports, and
several endpoint experiments are included.

The experiments found substantial room to reduce Apple Speech's endpoint wait, but did not establish
a semantic cutoff that was reliable enough for active use. Smart Turn therefore remains shadow-only,
and speculative partial synthesis is measured and discarded rather than played.

## How it works

```text
microphone
    -> on-device Apple Speech transcription
    -> finalized Japanese text
    -> Irodori synthesis server
    -> PCM16 WAV
    -> selected CoreAudio output
```

Apple Speech owns transcription, Irodori owns voice generation, and CoreAudio owns output routing.
The application does not use RVC or a cloud transcription API. The bundled Pipecat Smart Turn model
is an optional endpoint classifier, not an ASR replacement.

Irodori's current `/synthesize_stream` response is transport-streamed after the model has produced a
complete clip. It does not expose native incremental PCM generation, so request-to-first-audio time
still includes most of the synthesis work.

## Features

- On-device Japanese transcription with Apple Speech
- Final-only synthesis as the safe default
- Explicit CoreAudio output selection by device UID
- Reproducible PCM16 WAV replay for one-variable-at-a-time comparisons
- Content-free JSONL telemetry with per-stage latency reports
- Bounded synthesis and playback queues with cancellation and failure reporting
- Stable-prefix, silence-endpoint, Apple-finalization, and Smart Turn shadow experiments
- A native Swift Smart Turn v3.2 runtime using the bundled INT8 ONNX model

The project does not restart or redeploy Irodori, modify its voice bank, persist microphone audio, or
automatically fall back to the Mac's speakers when a configured output is unavailable.

## Requirements

- macOS 26
- Xcode 26 with Swift 6.3
- Node.js 24, `just`, and SwiftLint
- An Apple Silicon Mac with the Japanese Apple Speech assets available
- A reachable `irodori-tts-infra` synthesis server
- A CoreAudio loopback device, such as BlackHole, when routing the transformed voice into another app

The first `run` or `replay` may ask macOS to install the required Japanese Speech assets. Live use
requests microphone permission from the built `.app`; it does not modify the TCC database directly.

## Quick start

```bash
git clone https://github.com/ToaruPen/irodori-VoiceChanger.git
cd irodori-VoiceChanger
just bootstrap
just build-app
just config init
just devices
```

Edit the generated configuration at:

```text
~/Library/Application Support/IrodoriVoiceChanger/config.json
```

At minimum, set:

- `irodori.base_url`: use `http://127.0.0.1:PORT` for a local SSH tunnel, or HTTPS for a remote host.
  Plain HTTP is rejected for non-loopback hosts, and URLs containing credentials are rejected.
- `audio.output_device_uid`: use the exact UID printed by `just devices`, not the display name.

The versioned example uses the validated quality profile: 12 sampling steps, the `sway` schedule,
the `neutral` style, and a sway coefficient of `-1.0`.

Validate the configuration and runtime before starting live capture:

```bash
just config validate
just doctor
just doctor --synthesize
```

`doctor` is read-mostly. The `--synthesize` option sends one fixed, non-sensitive sentence and
validates the returned WAV. Neither command restarts, redeploys, or reconfigures the server.

## Live use

```bash
just run
```

The process prints `ready` after microphone, Speech, server, and output initialization completes.
Stop it with Control-C. Shutdown stops capture, finishes Apple Speech, and cancels in-flight Irodori
work.

Transcripts are hidden by default. Display them only for supervised debugging:

```bash
just run --show-transcript
```

To use the transformed voice in Discord, OBS, or another application, configure a loopback device as
`audio.output_device_uid`, then select that device as the application's microphone input. Monitor on
headphones through a separate output. Using the same loopback device as the system-wide output can
feed remote audio back into the call and create a doubled or echoing voice.

If the configured device is removed or reconfigured while the process is running, stop the process,
run `just doctor`, and start it again. Hot-unplug recovery is not implemented.

## Reproducible WAV replay

Use the same PCM16 WAV across conditions to compare behavior without changing microphone delivery:

```bash
just replay path/to/input.wav
just replay path/to/input.wav --synthesize
just replay path/to/input.wav --synthesize --live-output
just report latest
just report latest --json
```

`--synthesize` measures Apple Speech and Irodori but discards generated audio. Add `--live-output`
only when you intentionally want playback through the configured CoreAudio device.

## Experimental shadow modes

These modes are opt-in measurement tools. They are not production endpoint policies.

| Mode | Command or setting | Purpose | Audible or remote effect |
| --- | --- | --- | --- |
| Stable-prefix measurement | Set `speech.commit_policy.mode` to `stable_prefix` | Measure when an unchanged partial prefix appears and how it compares with the final transcript | None |
| Prefix synthesis shadow | `--shadow-synthesize-prefix` | Measure the latency and cost of synthesizing the first stable candidate | Sends one candidate to the configured Irodori server, then discards its audio; the normal final path remains separate |
| Silence endpoint shadow | `--shadow-endpoint-ms 100...3000` | Compare a fixed trailing-silence boundary with the later Apple final | None |
| Apple early-finalize replay | `--shadow-early-finalize-ms 100...3000` | Measure the mechanics of `SpeechAnalyzer.finalize(through:)` | Calls Apple finalize during speech-only replay; no Irodori request or playback |
| Smart Turn shadow | `--shadow-smart-turn` | Classify a 700 ms silence candidate from the latest eight seconds of audio | None; never calls Apple finalize, Irodori, or playback |

Examples:

```bash
just replay path/to/input.wav --synthesize --shadow-synthesize-prefix
just run --shadow-synthesize-prefix
just replay path/to/input.wav --shadow-endpoint-ms 1200
just run --shadow-endpoint-ms 1200
just replay path/to/input.wav --shadow-early-finalize-ms 300
just replay path/to/input.wav --shadow-smart-turn
just run --shadow-smart-turn
```

Smart Turn matched its Python reference on the saved fixed-WAV corpus, including three deliberately
incomplete pauses. In the live stress test, however, it classified five of six candidates followed by
resumed speech as complete. The repository therefore does not expose active Smart Turn finalization.
The normal `run` command remains final-only.

## Telemetry and privacy

Telemetry is stored locally as JSONL under:

```text
~/Library/Application Support/IrodoriVoiceChanger/telemetry
```

Files use mode `0600`, rotate at 5 MiB, and retain three generations by default. Events contain only
bounded operational data such as schema and correlation IDs, monotonic timestamps, stable event and
error codes, durations, byte counts, queue depths, partial revision counts, probability buckets, and
sampling steps.

Telemetry does not store:

- transcripts, partial text, final text, or text hashes
- microphone audio, generated audio, model features, or WAV paths
- voice IDs, device names or UIDs, server URLs, or credentials
- server response bodies

`report` reconstructs stage intervals and summarizes min/p50/p95/max values without revealing speech
content. A telemetry write failure does not stop normal audio processing, but the resulting evidence is
marked incomplete.

## Known limitations

- This is a macOS 26 proof of concept with no compatibility promise for older systems.
- Apple Speech finalization remains the largest ASR-side wait in the safe default path.
- The current Irodori endpoint returns audio after full-clip synthesis rather than native causal PCM.
- Stable-prefix candidates observed so far covered too little of the final utterance to justify playback.
- Fixed silence can split long pauses inside a sentence; longer thresholds give back much of the gain.
- Smart Turn did not safely distinguish deliberate incomplete pauses in the live stress test.
- The 8-step Irodori profile was faster but produced a noticeable quality regression in listening, so
  the shipped example and active local configuration remain at 12 steps.
- Generated clips can queue behind earlier playback when speech is divided into short utterances.
- CoreAudio hot-unplug recovery and segment stitching are not implemented.

## Validation evidence

The repository keeps measurements separate from the public introduction:

- [Initial microphone-to-Irodori baseline](docs/validation/2026-08-12-initial-baseline.md)
- [Stable-prefix and discarded candidate synthesis](docs/validation/2026-08-12-stable-prefix-shadow.md)
- [Apple Speech early-finalize replay](docs/validation/2026-08-13-early-finalize-shadow.md)
- [Native Smart Turn replay and live shadow](docs/validation/2026-08-13-smart-turn-native-replay.md)

Measurements use fixed WAV replay where possible, change one variable at a time, and avoid a fixed KPI
until the largest observed interval and the relevant quality tradeoff are known.

## Development

```bash
just format
just test
just test-cov
just check
```

`just check` runs strict formatting, SwiftLint, a warnings-as-errors build, tests and coverage, secret
scanning, `justfile` validation, and release app build/signing. Default tests do not require network
access, microphone permission, TCC prompts, a GPU, or audible output.

Source layout:

- `Sources/IrodoriVoiceChangerCore/`: platform-neutral contracts, pipeline, telemetry, and reports
- `Sources/IrodoriVoiceChangerMacOS/`: Apple Speech, AVFAudio, and CoreAudio adapters
- `Sources/IrodoriVoiceChangerCLI/`: commands and composition root
- `Sources/IrodoriVoiceChangerSmartTurn/`: native feature extraction and ONNX inference
- `Tests/`: deterministic unit and parity tests
- `docs/superpowers/`: accepted designs and implementation plans
- `docs/validation/`: privacy-safe experiment records

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

The application source is available under the [MIT License](LICENSE). The bundled Pipecat Smart Turn
model carries its own [BSD 2-Clause notice](Sources/IrodoriVoiceChangerSmartTurn/Resources/PIPECAT-LICENSE.txt).
