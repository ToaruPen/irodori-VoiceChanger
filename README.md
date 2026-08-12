# Irodori VoiceChanger

Irodoriの音質を保ったまま会話へ持ち込めるか。難しいのは音声合成そのものより、発話の終端をいつ確定し、完成した音声をどこまで早く再生へ渡せるかです。このPoCは、その待ち時間を推測ではなく発話ごとの計測値として分解します。

現在の経路は次のとおりです。

```text
microphone → Apple Speech → finalized text → Irodori → PCM16 WAV → selected CoreAudio output
```

RVC、Whisper、OpenAI API、mocoは使用しません。音声認識はmacOS 26のApple Speechをオンデバイスで使い、合成だけを既存のIrodoriサーバーへ送ります。

## 現在わかること

Apple Speechはpartialとfinalを逐次返しますが、基準経路がIrodoriへ渡すのはfinalだけです。partialは後から書き換わるため、先に合成すると発音済みの音声を取り消せません。まず正しい基準値を取り、その後に安定したprefixだけを先行確定する実験へ進めます。

Irodoriの`/synthesize_stream`は転送を分割します。しかし、現行Irodoriモデルが生成途中のPCMを逐次返すわけではありません。したがって`request_to_first_audio_ms`には、ネットワークだけでなくIrodoriが発話を完成させる時間も含まれます。この区別が、最初の最適化対象を決めます。

## 必要な環境

- macOS 26
- Xcode 26とSwift 6.3
- Node.js 24、`just`、SwiftLint
- 到達可能な`irodori-tts-infra`サーバー
- Discordへ渡す場合はBlackHoleなどのCoreAudioループバック出力

Apple Speechの日本語資産が未導入なら、初回の`run`または`replay`でOS管理の資産を取得します。live入力に必要なマイク権限は、固定bundle IDを持つ`.app`から要求します。新しいSpeechTranscriberに旧SFSpeechRecognizerの音声認識権限は要求しません。TCCデータベースを直接変更する手順もありません。

## セットアップ

```bash
cd ~/Dev/irodori-VoiceChanger
just bootstrap
just build-app
dist/IrodoriVoiceChanger.app/Contents/MacOS/irodori-voicechanger config init
dist/IrodoriVoiceChanger.app/Contents/MacOS/irodori-voicechanger devices
```

`~/Library/Application Support/IrodoriVoiceChanger/config.json`を開き、少なくとも次の2項目を実環境に合わせます。

- `irodori.base_url`: SSHポートフォワードなら`http://127.0.0.1:PORT`、リモート直結ならHTTPSのみ
- `audio.output_device_uid`: `devices`が表示した出力UID。名前ではなくUIDを指定

設定は未知のキーや資格情報入りURLを拒否します。出力UIDが見つからない場合も、Macのスピーカーへフォールバックしません。

```bash
just config validate
just doctor
just doctor --synthesize
```

通常の`doctor`は読み取り中心です。`--synthesize`を付けた場合だけ固定の非機密文を1回合成し、WAVまで検証します。サーバーの再起動、再配備、voice bankの変更は行いません。

## 実行

```bash
just run
```

起動準備が終わると`ready`が表示されます。停止はControl-Cです。認識内容は既定では画面にもログにも出ません。調整中にだけ確認する場合は`just run --show-transcript`を使います。

Control-CはマイクとApple Speechを停止し、進行中のIrodori requestをcancelします。BlackHoleを実行中に
削除・再構成した場合は、プロセスを止めて`just doctor`を再実行してください。このPoCはCoreAudio
deviceのhot-unplugを自動復旧しません。

Discordでは、設定したループバックデバイスを入力デバイスとして選びます。モニタリングはヘッドホンへ分けてください。同じループバックをシステム全体の既定出力にすると、Discordの相手の声まで再入力される可能性があります。

## 再現可能な検証

同じPCM16 WAVを使えば、マイクの話し方を変えずに認識・合成条件を比較できます。

```bash
just replay path/to/input.wav
just replay path/to/input.wav --synthesize
just replay path/to/input.wav --synthesize --live-output
just report latest
just report latest --json
```

`--synthesize`だけなら音声は捨て、ASRとIrodoriの時間を計測します。`--live-output`を加えたときだけ、設定済みCoreAudio出力へ再生します。

## テレメトリ

記録はローカルJSONLです。既定では`~/Library/Application Support/IrodoriVoiceChanger/telemetry`へmode `0600`で保存し、5 MiBごとに3世代までローテーションします。テレメトリ障害は音声経路を停止させませんが、`telemetry_unavailable`として扱える境界を保っています。

各イベントが持つのは次の情報だけです。

- schema version、session ID、utterance ID
- 単調時計のnanosecond timestamp
- stage、安定したevent/error code
- duration、音声長、server elapsed、byte count、queue depth、partial revision count、sampling steps

発話本文、音声、voice ID、端末名、出力名・UID、URL、資格情報、サーバーの応答本文は保存しません。

`report`は発話ごとに次の区間を復元し、min/p50/p95/maxを出します。

- 音声range終端 → first partial / Detector end / finalのdelivery（Apple Speechのaudio timeline基準）
- 音声range終端 → BlackHole再生開始
- ASR final → Irodori request
- request → stream handshake / first audio / complete
- server reported elapsed / request totalとの差
- playback enqueue → playback start
- speech end → playback start

入力buffer drop、失敗、最大queue depth、underrun、clip間gap、RTF、partialの書き換え回数も別に数えます。固定の合格数値はまだ置きません。最も大きい区間を測り、1条件ずつ変えて同じWAVで比較します。

このMacでの初回実機検証では、BlackHole、IrodoriへのSSH転送、Discord入力まで設定済みです。測定値と現在残るボトルネックは[初期検証記録](docs/validation/2026-08-12-initial-baseline.md)を参照してください。

## 開発

```bash
just format
just test
just test-cov
just check
```

`just check`はformat、SwiftLint、warnings-as-errors、core line coverage 90%以上、secretlint、release `.app`の署名検証をまとめて実行します。テストはネットワーク、TCCプロンプト、実音声出力を要求しません。

設計判断は[設計仕様](docs/superpowers/specs/2026-08-12-low-latency-voicechanger-design.md)、実装順序は[実装計画](docs/superpowers/plans/2026-08-12-low-latency-voicechanger.md)、実機の不足条件は[初期検証記録](docs/validation/2026-08-12-initial-baseline.md)に残します。
