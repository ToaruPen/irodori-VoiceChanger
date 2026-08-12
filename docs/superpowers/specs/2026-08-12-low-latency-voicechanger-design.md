# Irodori VoiceChanger 低遅延PoC設計

**Status:** Approved for implementation
**Date:** 2026-08-12

## 目的

Apple Silicon Mac上で、常時マイク入力をApple Speechで日本語テキストへ変換し、
Irodori-TTSへ短い発話単位で送り、生成された音声を選択したCoreAudio出力へ流す。
固定の合格値は置かず、音質を維持したまま各段階の遅延をどこまで短縮できるかを、
再現可能な計測で明らかにする。

このPoCはmocoから独立した新規macOSプロジェクトである。mocoのコード、Codex Realtime、
OpenAI API、RVC、クラウドASRには依存しない。mocoと`irodori-tts-infra`から取り入れるのは、
厳格な境界、決定的な品質ゲート、秘密・音声・本文を残さない運用方針である。

## 成功条件

初期リリースは次を満たす。

1. Apple Speechの`SpeechAnalyzer`、`SpeechTranscriber`、`SpeechDetector`を使い、
   日本語のpartial/final結果と発話境界を常時マイク入力から取得できる。
2. final発話をIrodoriのportable voice catalogとruntime generationに結び付けて合成できる。
3. 完成WAVを、システム既定出力ではなく選択したCoreAudio出力デバイスへ順序どおり再生できる。
4. 発声開始から再生完了までのボトルネックを、本文・音声を保存せずに発話単位で追跡できる。
5. 同じ外部WAVを投入するreplayで、設定変更前後を同条件で比較できる。
6. 実マイク、実Irodori endpoint、BlackHole等の実出力を使うlive検証は明示コマンドに隔離し、
   通常のテストとCIは外部サービス、マイク、音声モデル、仮想デバイスを必要としない。

## 非目標

- Irodoriモデルそのもののnative streaming化
- RVCまたは別のvoice conversion modelの追加
- Codex、ChatGPT、OpenAI APIの利用
- transcript、入力音声、生成音声の自動保存
- メニューバー、波形表示、話者編集等の製品UI
- Irodori serviceの配備、再起動、voice bank変更
- 現時点での固定レイテンシKPI

## 技術選択

### Swift 6単一プロセス

Swift 6.3、Swift Package Manager、macOS 26を使用する。Apple Speech、AVFAudio、CoreAudio、
URLSessionを同じprocessとmonotonic clockで動かす。Python helperや非公式bindingを挟まない。

実行物はCLIとして操作できる最小の`.app` bundleにする。SwiftPMでlibraryとexecutableを
buildし、versioned `Info.plist`を使ってbundle化・ad-hoc signingする。これにより、マイクと
音声認識のTCC権限を安定したbundle identifierへ結び付ける。GUIは持たず、foregroundで動く。

### Apple Speech

日本語`ja-JP`、`SpeechTranscriber.Preset.progressiveTranscription`、`SpeechDetector`を使う。
起動時にlocale、asset、権限、互換audio formatをfail closedで確認し、
`prepareToAnalyze`でwarmupしてからマイクを開始する。

初期commit policyはfinal-onlyである。partialは計測するがIrodoriへ送らない。正しいbaselineを
確立した後、stable-prefix実験を明示設定で追加できる境界を設ける。stable-prefixは、同一prefixの
観測回数と継続時間を満たした未送信suffixだけをcommitし、一度commitした本文の書き換えを許さない。
書き換えがcommit済み範囲へ及んだ場合は、その発話の投機結果を破棄してfinal-onlyへ戻す。

### Irodori HTTP契約

Swift側で必要最小限の公開契約をtyped modelとして実装する。Python packageへのsourceまたは
runtime依存は持たない。

- `GET /health`: `status=ok`かつ`model_loaded=true`
- `GET /capabilities`: `contract_version=1`、`ready=true`、一意なvoice catalog
- `POST /synthesize_stream`: requestごとに`voice_id`と`if_generation`を送る
- sampling初期値: `12 steps / sway / neutral / 1 candidate`

設定したvoice ID、またはcatalogの一意なdefaultを使用する。generation不一致、未知voice、
不正stream framing、上限超過はfallbackせず安定したfailure codeで停止・破棄する。

`/synthesize_stream`のhandshake到着、最初のaudio payload、final frameを別々に計測する。
現行Irodoriが完成WAV後にpayloadを返す事実を計測上も隠さない。

### CoreAudio出力

CoreAudioから出力可能デバイスを列挙し、表示名ではなく永続UIDで設定する。選択UIDが存在しない、
出力channelがない、formatを開けない場合は既定デバイスへ暗黙fallbackしない。

AVAudioEngineとAVAudioPlayerNodeでWAVをdecode・scheduleし、engineのoutput AudioUnitへ
`kAudioOutputUnitProperty_CurrentDevice`を設定する。再生キューは順序付きかつ上限付きとし、
enqueue、開始、完了、待ち時間、連続clip間gap、上限超過を計測する。

## アーキテクチャ

```text
MicrophoneCapture
    -> AnalyzerInput stream
    -> AppleSpeechSession
       -> SpeechBoundary events
       -> Partial/Final Transcript events
    -> CommitPolicy
    -> VoiceChangerPipeline
       -> IrodoriClient (/capabilities, /synthesize_stream)
       -> WAV validation
       -> PlaybackQueue
       -> CoreAudioPlayer(selected device UID)

Every boundary -> TelemetryRecorder -> bounded local JSONL -> report
External WAV   -> ReplaySource -------^ same pipeline and clock
```

境界はprotocolで分離するが、未採用backendの抽象化は作らない。protocolはテストdoubleと
実装交換に必要な`SpeechEventSource`、`Synthesizing`、`AudioPlaying`、`TelemetryRecording`、
`MonotonicClock`に限定する。

## Telemetry契約

### 原則

telemetryはローカル専用で、ネットワークexportを持たない。1行1eventのversioned JSONLとし、
`~/Library/Application Support/IrodoriVoiceChanger/telemetry/`へmode `0600`で書く。
1ファイル5 MiB、最大3世代でrotateする。書き込み失敗は音声処理をcrashさせないが、consoleへ
`telemetry_unavailable`を出し、session summaryを「不完全」とする。

次を保存しない。

- transcript本文、partial本文、文字数から復元可能なhash
- 入力音声、生成音声、WAV path
- voice ID、voice label、device name、device UID、endpoint hostname
- credential、header、URL、IP address、例外本文

consoleにも本文は既定で表示しない。`--show-transcript`を明示したforeground runだけ、
永続化しないdiagnostic表示を許可する。

### 相関と時計

process起動ごとに`session_id`、発話ごとに`utterance_id`を生成する。すべてのeventは、同じ
monotonic clockによるsession開始からの`timestamp_ns`を持つ。wall clockは日単位のrotation名以外に
使用しない。テストではfake clockを注入する。

### Event

- lifecycle: `session_started`, `session_ready`, `session_stopped`
- speech: `speech_started`, `speech_ended`, `asr_partial`, `asr_final`
- commit: `utterance_committed`, `utterance_rewrite_rejected`, `utterance_dropped`
- Irodori: `request_started`, `stream_handshake`, `first_audio_payload`, `request_completed`
- playback: `playback_enqueued`, `playback_started`, `playback_completed`, `queue_underrun`
- failures: `operation_failed`, stable `stage` and `error_code`

eventのmetadataはduration、audio duration、queue depth、byte count、partial revision count、
sampling profile、成功/失敗状態等のbounded scalarだけを許す。自由記述metadataは禁止する。

### Report

`report` commandはsessionごとにcount、min、p50、p95、maxを集計する。

- speech start -> first partial
- speech end -> final
- final/commit -> request start
- request start -> handshake / first audio / complete
- server-reported synthesis time
- client synthesis timeとaudio durationから算出したRTF
- synthesis complete -> playback start
- speech start / speech end -> playback start
- playback queue wait、最大depth、underrun、drop、failure count
- partial revision countとcommit済み範囲へのrewrite拒否数

sampleが少ない場合も補間せずnearest-rank percentileを使い、件数を必ず併記する。

## Concurrencyとbackpressure

Apple Speech resultの受信、Irodori synthesis、playbackを別actorへ分ける。Irodori requestは
serverのcapacity-one前提に合わせて1件ずつ送る。ASRは次の発話を継続でき、完成音声は
bounded playback queueへ入る。

上限は設定可能だが、初期値はpending synthesis 4発話、pending playback 4 clip、WAV 64 MiB、
1 clip 60秒とする。上限超過時は古い内容を黙って飛ばさず、新規発話を`utterance_dropped`として
明示し、現在再生中のclipは中断しない。これにより追従不能をtelemetryで観測できる。

## 設定

versioned JSONを`~/Library/Application Support/IrodoriVoiceChanger/config.json`から読む。
unknown key、型不一致、範囲外、credential埋め込みURLを拒否する。example configには次を含む。

- Irodori base URL、optional voice ID、sampling profile
- CoreAudio output device UID
- Speech locale、detector sensitivity、commit policy
- synthesis/playback queue上限
- telemetry directory、rotation上限

環境変数はtest fixtureと明示的なconfig path上書き以外に使わない。秘密は設定しない。

## CLI

- `config init|validate`: exampleからuser configを安全に作成・検証
- `doctor`: OS、locale asset、TCC、Irodori readiness、voice、出力deviceをread-only確認
- `devices`: 出力device名と設定用UIDを対話的に表示
- `run`: 常時マイク、自動発話区切り、合成、選択出力への再生
- `replay INPUT.wav`: 同一PCMをApple Speechから通し、任意でIrodori・再生まで検証
- `report [SESSION]`: content-free telemetry summaryをtableまたはJSONで表示

`doctor --synthesize`と`replay --live-output`だけが実Irodori合成または音声出力を行う。
通常doctorは状態を変更しない。

## エラー処理

内部errorはtyped enumへ正規化する。利用者向けにはstageとstable error codeを示し、URL、device UID、
transcript、remote response body、stack traceをtelemetryへ書かない。起動前条件の失敗はfail closed、
一発話の一時的Irodori失敗はその発話だけを破棄してsessionを継続する。連続3回のremote failure、
runtime generation変更、音声engine停止、Speech analysis終了はsessionを停止して再doctorを要求する。

## Repository構成と品質ゲート

```text
Sources/
  IrodoriVoiceChangerCore/    # models, config, pipeline, Irodori wire, WAV, telemetry
  IrodoriVoiceChangerMacOS/   # Apple Speech, AVFAudio, CoreAudio, permissions
  IrodoriVoiceChangerCLI/     # commands and composition root
Tests/
  IrodoriVoiceChangerCoreTests/
  IrodoriVoiceChangerMacOSTests/
config/                       # Info.plist and complete example config
scripts/                      # app bundling, coverage, deterministic checks
docs/superpowers/specs/
docs/superpowers/plans/
```

SwiftPM、Swift Testing、`swift-format`、compiler warnings-as-errors、coverage、secretlintを
`justfile`へ集約する。通常testはnetwork、microphone、TCC、実deviceを使わない。
coreはline coverage 90%以上を維持する。Speech/CoreAudioのhardware boundaryはprotocol adapterを
薄く保ち、fake source/playerによる契約testと明示的live testで検証する。

CIはformat、strict build、unit test、coverage、secret scan、release app bundle buildを実行する。
ローカルの最終gateは`just check`とする。

## 検証順序

1. fake clock/source/synthesizer/playerでevent順序、相関、backpressure、telemetry集計を確認する。
2. fixture WAVでstream parser、WAV validation、CoreAudio schedulingを確認する。
3. 外部WAV replayでApple Speechのpartial/finalとcold/warm差を測る。
4. 実Irodoriへ固定文を送り、handshake、first audio、complete、RTFを測る。
5. 選択した非既定出力へtest toneとIrodori音声を流し、device routingを確認する。
6. マイク常時入力でfinal-only baselineを複数発話測定する。
7. Speech detector sensitivity、audio buffer size、stable-prefix条件、queue上限を一変数ずつ比較する。

各比較は同一replay input、同一voice、同一sampling profile、warm/cold区分を保つ。最小値だけでなく
p50/p95、失敗、rewrite、underrun、dropを併記し、速さと正確性の交換を隠さない。

## 運用上の注意

Discordでは選択CoreAudio出力をBlackHole等にし、Discord入力を同じdeviceへ設定する。
自分のモニターにはheadphoneを使い、生成音声がマイクへ回り込む構成を避ける。
このPoCは同意のない人物のなりすまし用途を想定せず、利用するvoiceと場の規約を利用者が確認する。
