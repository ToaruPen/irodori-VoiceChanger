# Apple Speech早期finalize shadow検証 — 2026-08-13

## 結論

Apple Speechの確定待ちは、`SpeechAnalyzer.finalize(through: nil)`を使って実際に短縮できた。末尾無音候補からfinal結果が届くまではp50約45〜47msで、47回の要求はすべて完了し、失敗は0件だった。現在の同一WAV controlでは通常finalが音声range終端からp50 2985.9msかかったのに対し、早期finalize後は真の末尾で642.6〜714.8msだった。

ただし、無音だけを根拠に300/500msで確定すると、意味が完結した二文間の小標本で候補と確定結果の一致率が0.5になる例が各1件あった。700msでは12/12が一致率1.0で、最小coverageは0.8だった。したがって、Appleの機能自体はボトルネックを短縮できるが、最初の候補値は700msとする。

意味未完の日本語3例へ無音を入れた対照では、無音だけのApple早期finalizeは300/500/700msの全9件を二発話へ分割した。Appleは「文章が意味的に終わったか」を判断する境界判定器ではない。一方、別PoCのPipecat Smart Turn v3.2は同じ9観測をすべてholdとし、意味が完結した二文間はendとした。

採るべき構成は二者択一ではない。ASRはApple Speechのまま、Pipecatを意味的なゲートとして使い、700ms無音かつPipecat completeのときだけAppleへ早期finalizeを要求する。現時点ではreplay専用shadowのままで、Irodori送信・再生・live入力には接続しない。

## 実装境界

`replay --shadow-early-finalize-ms 100...3000`を明示した場合だけ、既存endpoint shadowの最初の候補からApple Speechへfinalizeを要求する。合成、live出力、prefix合成、既存endpoint flagとの併用はparserで拒否する。

finalize handlerへ渡すのは発話UUIDだけであり、本文やpartialは渡さない。telemetryは要求・完了・失敗・処理時間、既存の候補比較だけを記録し、本文、音声、文字数、hash、WAV path、voice、device、endpointを保存しない。失敗は安定した`speech_unavailable`として記録し、reportを不完全とする。

この実装はPipecatを含まない。Apple APIの機械的な効果と失敗境界だけを独立に検証するためである。

## 同一WAV replay

真の末尾1件と、意味が完結した二文間へ長さだけを変えたpause 6件を、300/500/700msで各1回replayした。合成と再生は無効である。pause音声では早期finalize後の後続音声を新しい発話として解析するため、操作数はセッション数より多い。

| 無音閾値 | finalize完了 / 要求 | 失敗 | pause分割 | 候補一致率1.0 | 最小一致率 | 最小coverage | finalize p50 / p95 | 候補→final p50 / p95 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 300ms | 13 / 13 | 0 | 6 / 6 | 12 / 13 | 0.5 | 0.5 | 44.0 / 55.9ms | 45.2 / 57.1ms |
| 500ms | 13 / 13 | 0 | 6 / 6 | 12 / 13 | 0.5 | 0.5 | 45.4 / 53.4ms | 46.7 / 54.4ms |
| 700ms | 12 / 12 | 0 | 5 / 6 | 12 / 12 | 1.0 | 0.8 | 44.7 / 59.7ms | 45.9 / 57.9ms |

700msでpause分割が5/6なのは、最短pauseが判定時点まで続かなかったためである。候補後の発話再開countが0なのは、finalize直後にmapperが発話状態を閉じ、後続音声を新しい発話として扱うためであり、分割の不存在を意味しない。

真の末尾1件だけを見ると、音声range終端からfinalまでは300/500/700msで702.1/642.6/714.8msだった。controlを直後に3回測り直したp50は2985.9msで、同じ時点の差は約2.27〜2.34秒である。過去の固定WAV controlは約0.36秒だったため、Apple frameworkの実行時変動が大きい。短縮の絶対値を実マイクへ外挿せず、finalize要求後約45msで確定結果が出たことを主な機械的証拠とする。

## 意味未完境界の対照

非機密の日本語合成音声3件を用意し、主題だけ、条件節だけ、動作の前置き節だけの位置へ約0.85〜0.98秒のpauseを入れた。無音だけの早期finalizeは全閾値で1回要求され、全9件を二発話へ分けた。

| 無音閾値 | 分割 | finalize完了 / 要求 | 失敗 | 候補一致率 | 最小coverage |
|---:|---:|---:|---:|---:|---:|
| 300ms | 3 / 3 | 3 / 3 | 0 | 3 / 3で1.0 | 0.5 |
| 500ms | 3 / 3 | 3 / 3 | 0 | 3 / 3で1.0 | 0.5 |
| 700ms | 3 / 3 | 3 / 3 | 0 | 3 / 3で1.0 | 0.8 |

候補とApple finalが一致していても、意味的に完結しているとは限らない。この実験ではstable prefix一致率を意味判定の代用品にできないことも確認できた。

同じ因果的prefixをPipecat Smart Turn v3.2へ渡すと、既定閾値0.5で未完境界は300/500/700msすべて0/3のend判定、真の末尾は各4/4のend判定だった。未完境界のcomplete scoreは0.009493〜0.039530、意味完結境界は0.987037〜0.989329である。推論p50は約31.7msだった。

## 判定

- Apple SpeechのASRと早期finalizeは維持する。
- PipecatはASR置換ではなく、700ms時点の意味ゲート候補にする。
- 既定threshold 0.5を使い、今回の小標本へ合わせた閾値調整はしない。
- live・Irodori・再生への接続は、Pipecatを含むshadowで実マイクの意味未完pauseを確認するまで行わない。
- Python環境を製品へ同梱する実装は過剰である。native runtimeの境界を決めるまでは、8.5MB ONNXモデルを外部PoCだけで評価する。

## 検証

- 実装前baseline: 117 tests / 18 suites pass
- 実装後: 124 tests / 19 suites pass
- `just check`: format、SwiftLint、warnings-as-errors build、95.58% core line coverage、secret scan、justfile、release app build/signingの全項目pass
- `git diff --check`: pass
- 合成、Irodori request、音声保存、音声再生: 0件

この段階ではactive useは未検証だった。その後のnative Smart Turn、live shadow、明示的なlive finalizeの結果は[Smart Turn native replay / live検証記録](2026-08-13-smart-turn-native-replay.md)にまとめた。
