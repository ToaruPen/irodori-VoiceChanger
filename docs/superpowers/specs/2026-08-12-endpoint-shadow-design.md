# 末尾無音endpoint shadow検証 設計

## 目的

Apple Speechのfinalを待つ約2.1秒を短縮できるか、アプリ側の末尾無音判定だけをshadow評価する。
通常のfinal-only合成・再生は変更せず、仮確定したpartialをIrodoriへ送らない。

## 実験条件

- 1セッションでは末尾無音閾値を1つだけ指定する。
- 比較条件は300ms、500ms、700msとする。
- 音声活動の固定判定値はRMS −45 dBFSとし、比較中は変更しない。
- 固定WAVには3秒の無音を末尾へ付加し、continuous inputの実マイク条件を再現する。
- 同一WAVを各条件5回replayし、価値がある条件だけ実マイクで確認する。

固定の合格KPIは置かない。候補の正確さ、候補からfinalまでの先行時間、発話再開、既存final経路の
失敗・dropを並べて判断する。

## 構成

`EndpointShadowMonitor`はplatform-neutralなactorとし、次の2入力だけを受ける。

1. `SpeechEvent`から発話ID、最新partial、finalを受ける。
2. macOS adapterがPCM bufferから算出した、音声活動の有無とbuffer継続時間を受ける。

発話中に連続無音が指定値へ達した最初の時点で、最新partialをメモリ内候補として保持する。候補後に
音声が再開した場合は、その境界が早すぎたことを別eventで記録する。final到着時に候補との共通prefixを
比較し、候補一致率とfinal coverageを0.1刻みに丸めて記録した後、本文を破棄する。

音声bufferのlevel計算はmacOS adapter内に置く。Coreの判定ロジックはAVFAudioへ依存させない。

音声入力とfinal pipelineをshadowのtelemetry待ちから切り離すため、adapterとSpeechEvent消費側は
enqueue時刻を付けて`EndpointShadowQueue`へ同期的にenqueueする。queueは256件までの有界とし、順序どおり
monitorを1consumerで更新する。monitorが保持するcontent-free eventも4,096件までに制限する。

endpoint telemetryは実行中に共有recorderへ書かず、通常pipeline停止後のqueue drain時にまとめて
flushする。telemetryが遅くてもAnalyzerInputのyieldとfinal合成開始は待たない。queueまたはevent上限を
超えた場合はshadowだけをfail-closedで停止し、`shadow_endpoint_overflow`でreportを不完全とする。

`replay --synthesize`はIrodoriと出力のpreflightが完了してからWAV入力streamを作る。
`AudioFileReplay`producerがSpeechEvent消費より先に進み、activity sampleを取りこぼす競合を防ぐ。

## CLIと安全境界

`run`と`replay`へ明示的な`--shadow-endpoint-ms VALUE`を追加する。値は100〜3000msに制限する。
flagなしではbuffer level計算を含めて既存動作を変えない。flagは`final_only`と`stable_prefix`のどちらでも
利用できるが、既存のstable prefix候補合成flagとは独立させる。

endpoint候補は合成、保存、再生、playback/synthesis queue投入をしない。失敗してもfinal pipelineを停止しない。

## Telemetry

新規eventは次の5つに限定する。

- `shadow_endpoint_enabled`: 発話がなくても、実験が有効だったことと閾値を記録する。
- `shadow_endpoint_candidate`: 指定無音へ到達した。候補の有無と閾値だけを記録する。
- `shadow_endpoint_speech_resumed`: 候補後に音声が再開した。
- `shadow_endpoint_final_comparison`: candidate→final時間、一致率、coverageを記録する。
- `shadow_endpoint_overflow`: 有界shadow queueまたはevent保持上限を超えた。

transcript、文字数、hash、音声level列、WAV path、device、endpointは記録しない。reportは候補数、再開数、
候補→final時間、一致率、coverageだけを既存形式で表示する。

## 検証

pure monitor、RMS判定、telemetry encode/decode、report、CLI parsingをRed→Greenで固定する。その後、
末尾無音付き同一WAVを300/500/700msで各5回replayする。実マイクは固定文を複数回読み、直後に無音controlを
実施する。実再生・候補合成・segment接続はこの検証範囲に含めない。

最初の比較で文中pauseによる誤境界が見つかった場合は、RMS閾値を変えず、末尾無音時間だけを
1000〜1800msへ延ばしたstress replayを追加する。これは当初条件の救済ではなく、固定silence方式の
安全性と残る短縮幅を測る一変数比較とする。
