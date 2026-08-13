# Stable partial prefix shadow検証 — 2026-08-12

## 結論

Apple Speechのfinalを待つ前に、後から書き換わらないprefixを観測できた。3 observations / 400msでは、
同一WAV 5回すべてで候補が成立し、最初の候補はspeech startからp50 1014ms、finalよりp50 1831ms先に
現れた。実マイクの意図した4発話でも候補範囲はfinalと100%一致し、rewriteとrollbackは0件だった。

しかし、thresholdを緩めても候補は早まらなかった。400msを250msへ短縮し、さらに観測回数を3回から
2回へ減らし、最後に50msまで下げても、候補時刻は約1.0秒のままだった。このWAVでは設定値ではなく、
Apple Speechのpartialが同じprefixを形成し始める時刻が床になっている。弱い条件を採用する理由はない。

先行時間だけを見れば、合成開始を早められそうに見える。そこで次の一段として、最初の候補をIrodoriへ
1回だけ送り、返った音声を保存・再生せず破棄するopt-in実験を追加した。固定WAV 5回と実マイク4発話で
candidate requestはすべてfinal前に完了し、通常のfinal合成・再生に明確な悪化は出なかった。

しかし、実際に送った最初の候補は短かった。fixed WAVではfinal coverageが5回とも0.1、実マイクでは
0.0–0.2で、生成音声も0.6–1.08秒に留まった。shadow-onlyで観測していた0.7–0.9は、final直前まで伸びた
最新候補のcoverageであり、最初に送れる候補の長さではない。したがって3 observations / 400ms、既定の
`final_only`、flagなしのshadow-onlyを維持し、候補音声の実再生やsegment接続には進まない。

## 実装境界

最初のshadow段階では、partialの連続観測を`Character`単位で比較するpure evaluator、発話単位のmonitor、
既存telemetry/reportへの接続だけを追加した。live、synthesis replay、speech-only replayは同じmonitorを
使い、Irodoriとplaybackのqueueはfinal eventだけを受け付ける既存経路のままである。

shadow telemetryは候補、rewrite、rollback、final比較のeventを持つ。本文、partial、final、文字数、
hash、WAV pathは保存しない。候補一致率とfinal coverage率は0.1刻みに丸める。unit testでは候補が成立
した後も`request_started`が0件で、final受信後だけ1件になることを固定した。

discard-only段階は`--shadow-synthesize-prefix`を明示した場合だけ有効になる。monitorが最初の候補を
メモリ内でhandlerへ渡し、handlerは発話ごとに1回だけ既存Irodori synthesizerを呼ぶ。返った`AudioClip`は
時間、音声長、byte countを記録した直後に破棄し、playerへ渡さない。final到着時は未完了taskをcancelし、
candidate failureは通常pipelineのfailure countやrestart判定へ混ぜない。flagなしの挙動は変わらない。

## 条件

- macOS 26、Apple Speech `ja-JP`
- 4.558秒、48kHz、mono、PCM16の同一固定WAV
- detector sensitivity: medium
- Irodori sampling profile: 12 steps / sway / neutral
- control: `final_only`
- shadow基準: 3 observations / 400ms
- synthesisなしの各replayは同じ入力と設定を使い、commit policyだけを変えた
- percentileは既存reportと同じnearest-rank

一時config、生成WAV、telemetryはrepo外に置いた。発話本文、voice ID、device UID、endpointは記録へ
含めていない。

## ControlとshadowのASR delivery

| condition | count | first partial p50 / p95 | final p50 / p95 | revisions | failure / drop |
|---|---:|---:|---:|---:|---:|
| final-only | 3 | 73.7 / 84.6ms | 391.7 / 422.3ms | 20 | 0 / 0 |
| shadow 3×400ms | 5 | 73.1 / 89.7ms | 377.2 / 381.7ms | 20 | 0 / 0 |

shadow追加後にfinal deliveryの悪化は観測されなかった。countが小さく、controlとshadowの分布差を改善と
主張できる設計でもないため、ここでは回帰が見つからなかったという判断に留める。

## 一変数ずつのthreshold比較

| observations | stable time | count | speech start → candidate p50 / p95 | candidate → final p50 / p95 | match | rewrite / rollback |
|---:|---:|---:|---:|---:|---:|---:|
| 3 | 400ms | 5 | 1015.1 / 1032.3ms | 1823.0 / 1851.0ms | 100% | 0 / 0 |
| 3 | 250ms | 5 | 1019.3 / 1021.5ms | 1824.6 / 1847.8ms | 100% | 0 / 0 |
| 2 | 250ms | 5 | 1010.1 / 1015.6ms | 1823.3 / 1834.5ms | 100% | 0 / 0 |
| 2 | 50ms | 5 | 1022.9 / 1033.6ms | 1829.0 / 1831.4ms | 100% | 0 / 0 |

差は一方向に動かず、約10–20msの測定揺らぎに収まった。最も弱い2×50msにも利得がないため、
3×400msより緩和しない。

## 小規模な内容差検証

単一WAVだけの偶然を避けるため、macOS標準日本語音声から作成した非機密3文のPCM16 WAVを追加した。
3×400msで候補は3/3に成立し、候補一致率はすべて100%、bucketed coverageは0.5–0.6だった。
rewrite、rollback、failure、dropは0件だった。

比率を0.1刻みに丸めた最終release buildでも固定WAVを5回再実行した。候補成立は5/5、
speech startから候補までのp50/p95は1013.5/1027.9ms、候補からfinalまでは
1830.7/1847.9ms、一致率は100%、bucketed coverageは0.7、rewrite、rollback、failure、dropは
すべて0件だった。追加3文も同じ最終buildで再実行し、結果は変わらなかった。

これは合成音声4標本の結果であり、人声、言い淀み、固有名詞、雑音、複数発話の連結を代表しない。
投機合成の安全性を示す証拠にはまだ足りない。

## 実マイク検証

同じ固定文を自然な速度で繰り返すliveセッションを、3 observations / 400msで実行した。ユーザーが
意図して発話した4回はすべて候補が成立した。候補はspeech startから876.1–1004.6msで現れ、finalより
4820.8–5831.9ms先行した。候補範囲のfinal一致率は4/4で100%、bucketed coverageは0.8–0.9、rewriteと
rollbackは0件だった。

Apple Speechはこの4回とは別に短いfinalを1件生成し、従来どおりfinalとしてIrodoriへ送った。本文を
保存していないため内容による判定は行っていない。入力はAG06/AG03、出力はBlackHole 2chであり、直後に
実施した約20秒の無音controlではutterance、partial、候補、Irodori requestがすべて0件だった。恒常的な
出力回り込みは再現せず、一過性ノイズなどによる追加検出として扱う。

意図した4発話と追加検出を合わせてもfailure、drop、rewrite、rollbackは0件だった。ASR final deliveryは
音声range終端からp50 2108.7ms、finalからIrodori requestまではp50 0.34ms、requestからfirst audioまでは
p50 721.3msだった。実マイクではfinal待ちが主要な遅延区間であり、stable prefix候補はその待ちより前に
得られている。

## Shadow-onlyの実Irodori経路

3×400msで固定WAVを1回だけ`replay --synthesize`へ通した。preflightはSpeech、出力device、Irodori
readiness、voice resolutionのすべてがpassした。shadow候補は発話中に6回前方へ伸びたが、
`request_started`、`request_completed`、playback enqueue/completionはいずれも1件だけだった。
最終release buildのrequestからfirst audioは607.6ms、server elapsedは596ms、failureは0件である。

partial候補は実Irodoriへ送られていない。final-only synthesisとdiscarding playbackは従来どおり完了した。

## Discard-only候補合成

同じfixed WAV、同じ3 observations / 400ms設定を使い、`--shadow-synthesize-prefix`の有無だけを変えて
5回ずつ比較した。どちらもfinal音声はdiscarding playerへ渡し、実出力していない。

| condition | final first audio p50 / p95 | final complete p50 / p95 | server p50 / p95 | audio end → playback p50 / p95 |
|---|---:|---:|---:|---:|
| control | 622.3 / 672.1ms | 654.2 / 704.1ms | 612 / 614ms | 1015.6 / 1073.3ms |
| discard candidate | 627.5 / 684.4ms | 656.1 / 713.6ms | 613 / 621ms | 1012.6 / 1083.0ms |

candidate requestは5/5で完了し、requestからfirst audioはp50/p95 568.3/661.9ms、completeは
575.4/668.6ms、server elapsedは554/639msだった。candidate failure、cancel、final failure、dropは0件で、
final playback completionも5/5である。controlとの差はp50で数ms、p95で約10msに留まり、この標本では
追加requestによる明確なfinal回帰は見つからなかった。

一方、first-candidateのfinal一致率は5/5で100%でもcoverageは全回0.1だった。生成音声も全回720msで
同一だった。一致していることと、独立して再生できる長さがあることは別である。

## 実マイクでのdiscard-only検証

同じ固定文を4回読むliveセッションでも、意図した4発話のcandidate requestはすべてfinal前に完了した。
first audioはp50/p95 583.2/677.9ms、completeは595.3/694.9ms、server elapsedは567/578msで、
candidate failure、cancel、rewrite、rollback、dropは0件だった。

| condition | count | final first audio p50 / p95 | final complete p50 / p95 | audio end → playback p50 / p95 |
|---|---:|---:|---:|---:|
| shadow-only | 4 | 721.3 / 827.6ms | 772.2 / 875.2ms | 2893.6 / 3049.0ms |
| discard candidate | 4 | 666.3 / 732.4ms | 768.0 / 782.6ms | 2850.6 / 2892.8ms |

各行はstable candidateが成立した意図発話だけを比較している。小標本かつ別takeなので改善とは判断しないが、
discard-only追加後の悪化も観測されなかった。通常finalのrequestは4回、playback completionも4回である。

first-candidate coverageは0.0–0.2、候補音声は0.6–1.08秒だった。最終的に安定した候補はfinalの0.8–0.9を
覆っていたため、問題は認識精度ではなく、最初に安全判定できる時点ではprefixがまだ短いことにある。

このセッションでは意図発話より前に、0.8秒と1.16秒の短いfinalが2件追加検出された。どちらもstable
candidateは成立せず、候補requestは発生していないが、従来のfinal経路では合成・再生された。本文を保存
していないため内容による分類はしていない。直後のflag有効20秒無音controlではutterance、candidate、
Irodori request、failure、dropがすべて0件で、恒常的な回り込みは再現しなかった。

## 次の境界

discard-only候補合成は、追加Irodori負荷とfinalへの回帰を可視化する実験として成立した。音声を保存・再生
せず、失敗も通常pipelineから隔離できている。このflagは計測用として残せる。

実再生には進まない。最初の安全な候補はfinalの0.0–0.2しか覆わず、短い断片を早く生成しても、自然な
発音やsegment接続を保証できないからである。次に検証すべき変数は安定時間の短縮ではなく、句読点、pause、
または別の発話境界で区切られた候補が十分な頻度で得られるかどうかである。そのshadow evidenceが出るまで、
ユーザーへ届く音声は従来どおりfinal-onlyとする。

## 末尾無音endpoint shadow

### 結論

入力PCMの末尾無音だけでもApple Speechのfinalより先に完全なpartialを得られる。ただし、短い閾値は
文中pauseを発話終端と誤認する。今回の固定silence方式では、品質回帰なしに約2秒を丸ごと削る根拠は
得られなかった。

通常の固定WAVでは500msと700msの候補がfinalへ100%一致し、coverageも1.0だった。500msは700msより
約0.24秒早い。ここだけを見れば500msを選べる。しかし、実効565msの文中無音を追加すると、300msと
500msは途中で候補を確定し、その後に発話が再開した。coverageは0.4に留まった。

閾値を延ばしても構造は変わらない。1200msは実効1.165秒の文中pause、1500msは実効1.565秒のpauseで
同じ誤境界を起こした。1800msは合成音声の最長pauseには耐えたが、後続の実マイク固定文では
1200/1500msが各1件、1800msが2件の候補後発話再開を記録した。1800msの1件は候補時点でfinalの0.1しか
覆わず、finalまで8.75秒あった。実マイクでも固定silence単独をcommitへ使える根拠は得られなかった。

固定silenceに絶対安全な有限値はない。話者が閾値より長く文中で止まれば、音響情報だけでは発話終了と
言い淀みを区別できないからである。endpoint候補は引き続きshadow-onlyとし、Irodori送信、再生、
final pipelineのcommitには使わない。

### 実装境界

`--shadow-endpoint-ms 100...3000`を明示した場合だけ、analysis formatへ変換済みのPCM bufferを固定
RMS −45 dBFSでspeech/silenceへ分類する。Coreの`EndpointShadowMonitor`は発話ID、最新partial、
Booleanのactivity sampleだけを受け、最初の連続無音到達時に候補をメモリ内へ保持する。final受信時に
比較して破棄する。

telemetry eventは有効化、候補、候補後の発話再開、final比較、overflowの5種類である。発話本文、文字数、hash、
bufferごとのlevel、入力音声、WAV pathは残さない。候補一致率とcoverageは0.1刻みである。有効化eventを
独立させたため、無音controlでも「flagが無効」と「有効だが候補0」を区別できる。

独立レビュー後、activityとSpeechEventは同一の順序付きshadow queueへ同期enqueueする形にした。
enqueue時刻も保持し、endpoint telemetryは実行中の共有recorderへ書かず、通常pipeline停止後にflushする。
そのため遅いtelemetryは音声入力とfinal合成を待たせず、candidate→final時間もflush遅延を含まない。
queueは256件、保持eventは4,096件までに制限し、上限時はshadowだけをfail-closedで停止してreportを不完全とする。
cancel後の入力は無視し、final比較が欠けた候補を含むセッションは`incomplete=true`とする。
`replay --synthesize`はIrodori/output preflightをWAV stream作成より先に完了させ、入力の先行消費も防いだ。

### 末尾無音付き同一WAV

既存の3.655秒、48kHz、mono、PCM16固定WAVへ3秒の無音を付加した。入力、detector sensitivity、
stable-prefix設定は固定し、endpoint thresholdだけを変更した。300/500/700msは各5回、追加thresholdは
各3回replayした。合成と再生は無効である。

| threshold | count | candidate→final p50 / p95 | match最小 | coverage最小 | speech resumed | Irodori request / failure |
|---:|---:|---:|---:|---:|---:|---:|
| 300ms | 5 | 3130.0 / 3180.7ms | 1.0 | 0.6 | 0 | 0 / 0 |
| 500ms | 5 | 2956.7 / 3145.2ms | 1.0 | 1.0 | 0 | 0 / 0 |
| 700ms | 5 | 2719.6 / 2745.2ms | 1.0 | 1.0 | 0 | 0 / 0 |
| 1000ms | 3 | 2543.1 / 2567.3ms | 1.0 | 1.0 | 0 | 0 / 0 |
| 1200ms | 3 | 2284.5 / 2296.1ms | 1.0 | 1.0 | 0 | 0 / 0 |
| 1500ms | 3 | 1938.9 / 1971.4ms | 1.0 | 1.0 | 0 | 0 / 0 |
| 1800ms | 3 | 1625.1 / 1643.3ms | 1.0 | 1.0 | 0 | 0 / 0 |

candidate→finalは3秒の末尾無音を持つpaced replay内のwall-clock差であり、実マイクの短縮値へそのまま
置き換えられない。比較軸は同じWAV上で閾値を延ばすほど候補が遅くなることと、候補時点のpartialが
完全かどうかである。

### Shadow計測自体のASR負荷

1200msのendpoint shadowがASR deliveryを悪化させないかを、同じ末尾無音付きWAVで確認した。
flagなしとflagありを5回ずつ交互に実行し、それ以外の設定は変えていない。

| condition | count | first partial delivery p50 / p95 | final delivery p50 / p95 | failure / drop |
|---|---:|---:|---:|---:|
| flagなし | 5 | 170.5 / 187.0ms | 2995.5 / 3062.2ms | 0 / 0 |
| endpoint 1200ms | 5 | 154.1 / 175.5ms | 2980.8 / 3061.9ms | 0 / 0 |

first partialとfinalともp50/p95はflagありのほうが0.4〜16.3ms小さかった。
小標本で改善や劣化を主張できる差ではない。ここでは固定RMS分類、shadow queueへのBoolean通知、
テレメトリ追加による明確なASR回帰が見つからなかったと判断する。両条件ともfailure、drop、incompleteは0だった。

レビュー修正後に、同じWAVを`--synthesize --shadow-endpoint-ms 1200`で1回通した。endpoint候補と
final比較は各1件、match/coverageは1.0、候補からfinalは2302.3ms、通常finalのplayback completionは1件だった。
failure、input drop、speech resumedは0、`incomplete=false`である。返った音声はdiscarding playerで破棄した。

### 文中pause stress

macOS標準日本語音声の非機密2文を連結し、その間へ無音を挿入した。音声自身の端部を含む−45 dBFS基準の
実効pauseは565、765、965、1165、1365、1565msだった。replayのactivity sampleは2048 frames、
約42.7ms単位なので、閾値付近にはbuffer単位の量子化がある。

| 実効pause | 300ms | 500ms | 700ms | 1000ms | 1200ms | 1500ms | 1800ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 565ms | resume / 0.4 | resume / 0.4 | no resume / 0.9 | — | — | — | — |
| 765ms | resume / 0.4 | resume / 0.4 | resume / 0.4 | — | — | — | — |
| 965ms | resume / 0.4 | resume / 0.4 | resume / 0.4 | resume / 0.4 | no resume / 1.0 | no resume / 1.0 | — |
| 1165ms | — | — | — | — | resume / 0.5 | no resume / 1.0 | no resume / 1.0 |
| 1365ms | — | — | — | — | resume / 0.5 | no resume / 1.0 | no resume / 1.0 |
| 1565ms | — | — | — | — | resume / 0.5 | resume / 0.5 | no resume / 1.0 |

各セルは`候補後の発話再開 / final coverage`である。すべての候補はfinalのprefixとしては一致率1.0で、
Irodori requestとfailureは0だった。問題は誤認識ではない。正しい文の途中を、正しいまま早く切って
しまうことである。

### 実マイク無音control

1200msを有効にした約20秒のlive無音controlでは、utterance、endpoint candidate、speech resumed、
Irodori request、failure、input dropがすべて0だった。`shadow_endpoint_enabled`は1200msを記録し、
実験が有効だったことを確認できた。

### 実マイク固定文比較

同じ固定文を各条件4回読み、1〜2回目は通常、3〜4回目は文中で意図的に間を置いた。設定はendpoint
thresholdだけを1200、1500、1800msへ変更した。人の読み方は完全には再現できないため、条件間の数十ms差を
性能差とは扱わず、候補後発話再開と候補時点のcoverageを安全性の主な比較軸にした。

| threshold | utterance / candidate | candidate→final p50 / p95 | match最小 | coverage最小 | speech resumed | audio end→ASR final p50 / p95 | failure / input drop |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1200ms | 4 / 4 | 1918.5 / 8426.9ms | 1.0 | 0.1 | 1 | 2044.9 / 2097.7ms | 0 / 0 |
| 1500ms | 4 / 4 | 1444.1 / 2054.0ms | 1.0 | 1.0 | 1 | 2116.4 / 2125.0ms | 0 / 0 |
| 1800ms | 4 / 4 | 1644.3 / 8749.8ms | 1.0 | 0.1 | 2 | 2092.3 / 2094.9ms | 0 / 0 |

全候補はfinalのprefixとして一致したが、3条件すべてで候補後に発話が再開した。正しい文字列であることは、
その位置で発話を終了してよいことを意味しない。各セッションの`utterance_dropped` 1件は4件目の再生開始後、
手動停止までに再生が完了しなかったためである。4件ともASR final、Irodori request、first audio、
playback startまでは完了し、failureとinput dropは0だったため、endpoint thresholdによる回帰とは扱わない。

audio endからASR finalまでは3条件のp50で2.04〜2.12秒、Irodori requestからfirst audioまでは
p50 0.56〜0.65秒だった。候補からfinalまでの時間は短縮可能量の上限に見えるが、途中再開した候補を含むため、
品質を維持した実利用上の短縮量ではない。

### 次の安全境界

固定silence方式は計測器として残せる。300〜1500msはreplay pause stressで反証され、実マイクでは1800msを
含む全条件で候補後発話再開が出た。したがってendpointによるcommitやcandidate synthesisは実装しない。

次に1変数だけ進める場合も、音響silenceの閾値調整ではなく、句読点、partial安定性、明示的なpush-to-talk
など別の境界情報をshadowで評価する。その候補が自然な言い淀みを誤終端せず、十分な先行量を反復して示すまで、
既定はfinal-onlyのままとする。
