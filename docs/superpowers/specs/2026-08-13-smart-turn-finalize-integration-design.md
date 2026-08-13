# Smart Turn semantic finalize integration design

## Goal

Keep Apple Speech as the Japanese ASR and measure whether a local semantic gate could safely reduce
its slow implicit endpoint wait. After 700 ms of silence, Pipecat Smart Turn v3.2 classifies the
causal audio seen so far. Complete and incomplete decisions are telemetry only: neither replay nor
live calls `SpeechAnalyzer.finalize(through:)`, Irodori, or playback from a semantic decision.

The retained implementation has two gates: deterministic replay shadow and live shadow. A temporary
explicit live experiment was measured and then removed after the live shadow quality gate failed.

## Approaches considered

### Native Swift ONNX Runtime — selected

Add Microsoft's official `onnxruntime-swift-package-manager` package, bundle the 8.5 MB
`smart-turn-v3.2-cpu.onnx` resource and its BSD-2-Clause notice, and reproduce Pipecat's current
Whisper log-mel preprocessing in Swift. This is the only approach that exercises the intended
product runtime without Python, a helper process, network audio, or model conversion.

### Python sidecar — rejected for integration

The existing offline PoC already proves the Python path and remains the reference oracle. A
sidecar would reach live shadow sooner, but process startup, environment discovery, IPC and Python
packaging would be measured instead of the eventual app. It remains a test oracle only.

### Core ML conversion — deferred

Core ML could remove the ONNX Runtime dependency, but conversion changes the executable model and
would require a new numerical validation campaign. The measured ONNX CPU inference is already small
relative to the expected latency reduction, so conversion has no demonstrated value yet.

## Runtime boundaries

Create one focused Smart Turn target. It owns:

- an in-memory, bounded audio window for the current Apple utterance;
- resampling to 16 kHz mono;
- the exact Pipecat v3.2 waveform normalization, centered 400-sample Hann STFT, 80-bin Slaney mel
  filterbank and `(80, 800)` Float32 feature tensor;
- one sequential, single-threaded ONNX Runtime session;
- the fixed `probability > 0.5` complete decision.

The endpoint queue delivers ordered speech events and in-memory mono PCM frames to the semantic
handler. Audio is retained for at most eight seconds, never written, and cleared on final,
cancellation or a new utterance. The handler may request another decision only after an incomplete
candidate is followed by resumed speech and another 700 ms silence. It never polls repeatedly in
one silence.

The Core target continues to own endpoint state and content-free telemetry contracts. The macOS
target remains the adapter for `AVAudioPCMBuffer` and Apple Speech. The CLI composition root creates
the concrete classifier. Semantic decisions remain shadow-only and are never joined to
`EndpointFinalizationHandler` in this change.

## Staged activation

### Gate 1: replay semantic shadow

Add a replay-only opt-in that runs the native classifier without calling Apple early finalize. It
remains speech-only: no Irodori request, output device or playback. Run the
same true-end WAV, the six meaning-complete pause variants, and the three meaning-incomplete pause
variants. Compare native decisions with the pinned Python oracle.

Pass conditions:

- native complete/incomplete decisions equal the Python oracle for every causal probe;
- all three incomplete boundaries are classified incomplete;
- true ends and meaning-complete boundaries are classified complete;
- native inference plus feature preparation remains materially below the saved ASR wait.

### Gate 2: live semantic shadow

Add a separate live shadow opt-in. It runs the classifier and records the decision but never calls
Apple finalize. The existing Apple-final-to-Irodori-to-playback path remains unchanged. The user
speaks ordinary complete utterances and three deliberate incomplete pauses. Telemetry measures
decision counts, rounded score buckets, inference time, later speech resumption, Apple final lead,
failures and input drops.

Pass conditions:

- intended complete turns are detected;
- deliberate incomplete pauses do not produce a complete decision;
- no classifier failure, queue overflow or input drop is introduced;
- the native compute cost leaves a material end-to-end lead.

### Gate 3: rejected active connection

Gate 2 failed. A temporary opt-in live connection supplied useful timing evidence, but the semantic
quality failure and candidate-time race made it unsuitable to retain. The active path and its CLI
flag were removed. No replay or live semantic decision calls Apple finalize. No speculative partial
synthesis, segment stitching, model threshold sweep, automatic fallback to fixed silence, or
default activation is included.

## Telemetry and failure behavior

Add stable content-free events for classifier requested, completed and failed. Completion records
only duration, a probability rounded to coarse buckets, and complete/incomplete. It does not record
audio, transcript, partial text, feature tensors, paths, hashes, voice, device, endpoint or model
input identifiers.

Model absence, preprocessing failure, invalid tensor shape, non-finite output and ONNX Runtime
failure fail closed. Replay reports the failure as incomplete evidence. Live shadow leaves the
existing final path untouched and reports the failure.

## Tests

Use Red → Green → Refactor for each behavior. Deterministic tests cover:

- periodic Hann, Slaney filterbank, normalization and feature-shape parity against non-speech
  synthetic vectors generated by the pinned Python oracle;
- native ONNX probability and decision parity for zero, sine, impulse and 48 kHz resampling oracle
  inputs; the external 15-case public synthetic WAV comparison remains saved validation evidence;
- eight-second bound, utterance reset and retry-after-resumption behavior;
- complete and incomplete decisions remaining shadow-only;
- CLI mutual exclusions and default-path preservation;
- telemetry round-trip, coarse bucketing and absence of speech content;
- missing model and inference failure behavior.

The full `just check` gate must pass before each live stage. No commit or push is performed without
explicit user authorization.
