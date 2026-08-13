# Smart Turn native replay / live検証 — 2026-08-13

## 結論

Pipecat Smart Turn v3.2はApple Speechを置き換えるASRではなく、Appleの確定処理を早めてよいかを判定する小さな音声モデルとしてnative Swiftへ組み込めた。固定WAVではPython参照実装と15/15件でcomplete/incomplete判定が一致し、意味未完の3例をすべてholdした。推論p50は84.38msだった。一時的なactive replayではAppleの早期finalize自体がp50 18.42msであり、機械的には約2秒あるAppleの確定待ちを大きく削れることも確認した。

ところが、同じ既定閾値0.5と700ms無音を実マイクへ持ち込むと結果が反転した。発話が再開した6候補のうち、正しくincompleteと判定できたのは1候補だけで、残る5候補をcompleteと判定した。さらに、発話再開なしで残った1候補はApple finalとの一致率・coverageがともに0だった。推論は速いが、確定対象の品質が足りない。

この結果から、Smart Turnを一般的な意味境界判定器として既定経路へ入れる条件は満たさなかった。その後、通常のつなげ読みでの体感を確認するため、明示的なlive finalizeを一時的に接続して700ms、次に500msを一変数ずつ実測した。ただしGate 2の誤completeはモデル品質の問題として残った。さらに、推論中に発話が再開すると候補より後の音声まで確定し得る競合がレビューで見つかり、安全な候補音声時刻の伝播は今回のPoCを超えると判断した。そのためactive経路とflagを削除し、semantic処理をreplay/liveともshadow-onlyへ戻した。通常の`run`は従来のfinal-only経路のままである。

## 実装境界

macOS appへONNX Runtime 1.24.2とPipecat Smart Turn v3.2のINT8 ONNXモデルを同梱した。Swift実装は直近8秒のmono PCMだけをメモリ上で保持し、Pipecat互換のWhisper featureを生成してcomplete確率を得る。判定後に発話が再開した場合だけ、次の無音候補を再評価する。

replayとliveの`--shadow-smart-turn`は判定時刻と結果を記録するだけで、Apple final、Irodori request、再生の既存経路を変えない。semantic active finalizeは提供しない。

telemetryにはrequested/completed/failed、推論時間、4段階の確率bucket、completeの真偽だけを保存する。音声、feature、発話本文、partial、final、hash、文字数、WAV path、voice、device、URLは保存しない。

## Gate 1: 同一WAV replay — 現行shadow-only

真の末尾1件、意味が完結したpause 6件、意味未完のpause 3件を、既定閾値0.5・700ms無音でreplayした。すべて同じWAVをPython参照実装とnative実装へ渡し、合成と再生は無効にした。

| 観測 | 結果 |
|---|---:|
| semantic判定 | 15件 |
| Pythonとのcomplete/incomplete一致 | 15 / 15 |
| 意味未完pauseのhold | 3 / 3 |
| complete判定 | 12件 |
| semantic失敗 | 0 |
| semantic推論 p50 / p95 | 84.38 / 86.91ms |
| input drop / endpoint overflow | 0 / 0 |

現行の`--shadow-smart-turn`は判定だけを記録し、Apple finalizeを要求しない。固定入力におけるnative classifierの再現性と意味未完pauseのholdについて、Gate 1は通過した。

### 一時的なactive replay計測（削除済み）

次の数値は、semantic completeをApple finalizeへ一時的に接続して測定した結果である。現在の実装にこの接続はなく、同じactive経路を再現するCLI flagも提供しない。

| 観測 | 結果 |
|---|---:|
| finalize完了 / 要求 | 12 / 12 |
| finalize失敗 | 0 |
| Apple finalize p50 / p95 | 18.42 / 27.24ms |
| 候補とfinalの一致率 | 12 / 12で1.0 |
| final coverage | 最小0.7、p50 0.9 |

単純な真末尾WAVでは、通常controlの音声range終端→finalが約2985.9msだったのに対し、一時的なsemantic gate後は740.94msだった。この1件では候補→finalが105.12ms、候補とfinalの一致率・coverageはともに1.0である。この計測は短縮余地の証拠であり、現行機能の説明ではない。

## Gate 2: 実マイクlive shadow

4文を読み、うち3文では条件節や接続節の直後に約1.5秒の意味未完pauseを置いた。通常のIrodori再生が終わってから次の文へ進み、transcript表示は無効にした。session IDは`03AD887E-DD85-46EF-9236-8476D12DAE21`である。

| 観測 | 結果 |
|---|---:|
| Apple utterance / Irodori再生 | 4 / 4 |
| 700ms無音候補 | 7件 |
| 候補後に発話再開 | 6件 |
| 再開した候補をincomplete判定 | 1 / 6 |
| 再開した候補をcomplete判定 | 5 / 6 |
| 再開なし候補をcomplete判定 | 1 / 1 |
| semantic推論 p50 / p95 | 82.61 / 83.11ms |
| 候補→Apple final p50 / p95 | 2137.93 / 2733.50ms |
| 音声range終端→Apple final p50 / p95 | 2048.91 / 2061.94ms |
| Irodori request→first audio p50 / p95 | 679.41 / 691.90ms |
| 音声range終端→再生 p50 / p95 | 2767.21 / 2800.16ms |
| semantic失敗 / input drop | 0 / 0 |

速度の余地は明瞭だった。候補はApple finalよりp50約2.14秒早く、約83msの意味判定を差し引いても約2秒残る。Irodoriのfirst audioもp50約0.68秒なので、確定対象が正しければ体感待ち時間を大きく縮められる。

しかし、その前提を実マイクが満たさなかった。発話再開は「その候補で確定してはいけなかった」ことを後から確認できる観測であり、その6件中5件をcompleteにした誤分割率は83.3%である。加えて、再開せず残った候補のApple final比較は一致率0、coverage 0だった。固定WAVで一致したcandidate比較がliveだけ崩れており、Apple partialの書き換え前テキストを送る危険も残る。

Gate 2は不合格とする。

## Gate 3: 明示的なlive finalize

Gate 2は意図的に約1.5秒の意味未完pauseを置くstress testであり、その条件での誤分割リスクは残る。一方、実際にはつなげて読む文はつなげ、区切る文は区切るという利用条件で体感と実測を確認するため、既定経路を変えないopt-inとしてlive finalizeを接続した。最初は700ms、次に無音閾値だけを500msへ変更した。

| 観測 | 700ms | 500ms |
|---|---:|---:|
| session | `AC5F6717-3198-4557-9388-BCA1F9C6CEC2` | `BA24346E-D5EC-41CA-A5B0-4262F9DB5944` |
| Apple utterance / Irodori再生 | 11 / 11 | 9 / 9 |
| semantic要求 / complete / incomplete | 10 / 9 / 1 | 9 / 9 / 0 |
| finalize完了 / 要求 | 9 / 9 | 9 / 9 |
| semantic推論 p50 / p95 | 81.86 / 85.95ms | 83.51 / 86.84ms |
| Apple final delivery p50 / p95 | 113.86 / 2079.50ms | 118.08 / 173.48ms |
| Irodori request→first audio p50 / p95 | 562.29 / 630.42ms | 516.67 / 589.14ms |
| 音声range終端→再生 p50 / p95 | 733.28 / 2619.22ms | 716.64 / 1224.55ms |
| playback queue wait p50 / p95 | 0.25 / 2.09ms | 0.29 / 610.69ms |
| queue underrun | 0 | 2 |
| semantic/finalize failure / input drop | 0 / 0 / 0 | 0 / 0 / 0 |

500ms条件のIrodori request→first audioのp50は700ms条件より45.62ms、音声range終端→再生のp50は16.64ms小さかった。ただし入力文が異なる実マイクセッションなので、閾値だけによる短縮とは断定できない。500msでは短い断片が前の音声の再生中に完成し、playback queue waitのp95が約611msへ増えた。生成を早く始めても、出力が詰まるとtail latencyは改善しない。

さらに実装レビューで、候補時点の音声snapshotを分類してから`finalize(through: nil)`を呼ぶまでに発話が再開すると、候補より後にAppleが消費した音声まで確定し得ることが分かった。候補音声時刻をAppleへ伝播する仕組みは今回のshadow PoCを超えるため追加せず、semantic replay/liveとも判定だけを残してactive modeを削除した。

## 採否

- Apple SpeechをASRとして維持し、通常経路はfinal-onlyのままにする。
- Smart Turn native実装とreplay shadowは、再現可能な比較実験のために残す。
- liveは`--shadow-smart-turn`だけを公開し、Apple finalize、Irodori request、再生へ接続しない。
- semantic active finalizeは提供しない。意味未完pauseの誤completeと安全な候補音声時刻契約が未解決である。
- 今回の小標本へ合わせたthreshold調整は行わない。同じlive音声を保存しておらず、事後調整するとone-variable-at-a-timeの再現可能な比較にならないためである。
- 投機合成、segment接続、モデル追加探索へは進まない。現時点で確認できた価値は「確定待ちを約2秒削れる機械的余地」であり、「品質回帰なしに削れること」ではない。

## 検証

- 現行shadow-only classifier: Python参照判定15/15一致、Apple finalize要求0件
- 実マイク: 4 utterances、7 semantic decisions、4 Irodori playbacks
- 現行shadow-onlyのsemantic failure、input drop、endpoint overflow: 0件
- 削除済みの一時live finalize計測: 700msで11 utterances / 11 playbacks、500msで9 / 9
- 削除済み経路のsemantic/finalize failure、input drop: 0件
- `just check`: format、SwiftLint、warnings-as-errors build、全test、coverage、secret scan、justfile、release app build/signingを実行
- 発話本文・音声の保存、transcript表示: 0件
- partialのIrodori送信、投機再生: 0件
