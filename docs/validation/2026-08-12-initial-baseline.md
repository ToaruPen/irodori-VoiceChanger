# 初期実機検証 — 2026-08-12

## 結論

マイクからDiscord入力までの経路は実機で動作した。20秒のライブ測定では5発話がApple
Speech、Irodori、BlackHoleを順に通過し、5件とも再生を完了した。入力drop、queue
underrun、処理失敗は0件だった。

ただし、現時点の体感は連続リアルタイム変換ではない。音声range終端からBlackHole再生開始までの
p50は2755ms、p95は2787msである。このうちApple Speechがfinalを返すまでのp50が
2094ms、Irodoriサーバー処理のp50が619msを占めた。Irodoriだけを速めても、約2秒のASR確定待ちは
残る。

## 環境とセットアップ状態

- macOS 26.5.1、Apple Silicon
- Swift 6.3.3、Xcode 26.6
- Apple Speech `ja-JP`: supported / installed
- commit policy: final-only
- Irodori: 12 steps / sway / neutral
- CoreAudio loopback: BlackHole 2ch
- Discord input: BlackHole 2ch、入力プロフィール「スタジオ」

BlackHoleは公式2chドライバを導入し、再起動後に入力・出力デバイスとして認識された。VoiceChangerの
user configとrepo-local configはどちらもBlackHoleを明示選択しており、既定スピーカーへのfallbackは
ない。

Irodoriは既存配備のvoice bank 13話者を検証してから起動した。voice bankの置換、再配備、runtime
generationの変更は行っていない。Mac側のSSH loopback転送は
`~/Library/LaunchAgents/dev.toarupen.irodori-voicechanger-tunnel.plist`へ登録し、ログイン時の起動と
接続断後の再接続を有効にした。転送は`127.0.0.1:8924`だけで待ち受け、LANへ公開しない。

ホスト名、デバイスUID、voice ID、発話本文、入力音声、生成音声はこの記録に含めない。

## Preflight

| check | result | evidence |
|---|---|---|
| app bundle | pass | ad-hoc署名と固定bundle IDを`codesign --verify --deep --strict`で検証 |
| microphone permission | pass | bundled appに対するTCC許可を`doctor`で確認 |
| Japanese locale / asset | pass | `SpeechTranscriber`と`AssetInventory`で確認 |
| virtual output | pass | BlackHoleをCoreAudio出力としてUID解決 |
| Irodori readiness | pass | SSH転送後のhealth、capabilities、voice解決を確認 |
| fixed synthesis probe | pass | `doctor --synthesize`でframed WAVを1件検証 |
| Discord input | pass | Discord UIでBlackHole選択状態を確認 |

## 固定WAVのE2E baseline

macOS標準音声から作成した3.655秒、48kHz、mono、PCM16の固定WAVを3回使用した。条件は
final-only、medium sensitivity、12 stepsで、Irodori出力はBlackHoleへ再生した。

| interval | p50 | p95 |
|---|---:|---:|
| audio range end → first partial delivery | 59.7ms | 66.6ms |
| audio range end → final delivery | 362.8ms | 407.1ms |
| request → handshake | 10.8ms | 71.5ms |
| request → first audio payload | 608.0ms | 728.7ms |
| Irodori server elapsed | 598ms | 657ms |
| detector end delivery → playback start | 631.2ms | 751.0ms |
| synthesis RTF | 0.166 | 0.197 |

3回ともplayback completedは1、drop、failure、underrunは0だった。first payloadはIrodoriが完成WAVを
生成した後に届くため、requestからfirst payloadまでの大半はサーバー生成時間である。

## 実マイク baseline

final-only、medium sensitivity、12 stepsの20秒セッションで5発話を処理した。同じ発話内容を
繰り返した統制実験ではないため、固定WAVの数値とは分けて扱う。

| interval | count | p50 | p95 |
|---|---:|---:|---:|
| audio range end → first partial delivery | 4 | 29.2ms | 98.4ms |
| audio range end → final delivery | 5 | 2094.0ms | 2141.8ms |
| audio range end → playback start | 5 | 2755.2ms | 2787.0ms |
| final → Irodori request | 5 | 0.3ms | 1.0ms |
| request → first audio payload | 5 | 631.7ms | 651.6ms |
| Irodori server elapsed | 5 | 619ms | 637ms |
| delivered speech end → playback start | 5 | 656.4ms | 665.4ms |
| synthesis complete → playback start | 5 | 0.7ms | 2.2ms |

5発話すべてが再生完了し、input drop、queue underrun、failureは0だった。最大区間はIrodoriではなく、
Apple Speechがcontinuous input上でfinalを確定するまでの待ち時間である。`speech_end_to_playback`だけを
見ると約0.65秒に見えるが、この起点はDetector結果がアプリへ届いた時刻であり、その前のASR待ちを
含まない。`audio_end_to_playback_ms`が利用者の待ち時間に最も近い。

## 最初の最適化実験

### Detector-driven finalize

SpeechDetectorのend通知時に`SpeechAnalyzer.finalize(through:)`を呼ぶ実験を行った。同一WAVのfinal
delivery p50は変更前362.8ms、変更後364.0msで差がなかった。ライブ比較も2094msから2069msへの
25ms差に留まり、発話内容とqueue条件が統制されていないため改善とは判定しなかった。実験コードは
残さず、Detector通知遅延を測るtelemetryだけを残した。

### Detector sensitivity

同一WAVをIrodoriなしで各3回replayした。mediumのDetector end delivery p50は358.9ms、highは
324.2msで、highが34.7ms短かった。約9.7%の差は確認できたが、実マイク全体の約2.8秒に対して小さく、
高感度化による誤起動を評価していない。実利用設定はmediumのままとした。

### Irodori sampling steps

固定の非機密文を各3回合成し、設定は一時ファイルだけで変更した。音質評価を伴わないため、実利用設定は
12 stepsのままである。

| steps | server elapsed p50 | request → first audio p50 | 12 steps比 |
|---:|---:|---:|---:|
| 12 | 527ms | 538.6ms | baseline |
| 8 | 395ms | 408.6ms | -130.0ms |
| 6 | 383ms | 396.1ms | -142.6ms |
| 4 | 313ms | 324.2ms | -214.5ms |

4 stepsまで下げても短縮は約214msで、現状のASR final待ち約2.1秒は残る。8から6 stepsの差は約13msに
縮んでおり、品質を犠牲にして6以下を採用する根拠はまだない。

## 実機で見つかった不具合

実機経路を通したことで、通常のunit testだけでは見つからなかった3件を修正した。

1. `report latest`が再起動前のsessionを返した。monotonic timestampは再起動で小さくなるため、最大値
   ではなくJSONLのappend順で最新sessionを選ぶよう変更し、archive読込順も修正した。
2. マイクtap callbackが`@MainActor`を継承し、AVAudioのrealtime queueでSwift 6 executor checkに
   よりSIGTRAPした。callback生成をnonisolated factoryへ移し、main executor外の回帰テストを追加した。
3. READMEどおりの`just run`がライブ起動せずhelpを表示した。内部CLI recipeを分離し、dry-run契約を
   `scripts/check-justfile.sh`で検査するようにした。

## 最終検証

セットアップ後に`just format && just check`を実行した。Swift format、SwiftLint、
warnings-as-errors build、70件以上のtests / 13 suites、core line coverage 90%超、secretlint、
release app bundleの生成と署名検証がすべて通過した。`AGENTS.md` auditと`git diff --check`も
エラーなしだった。

再起動後の実環境では、設定検証、BlackHoleの出力解決、Apple Speechの日本語資産、マイク権限、
Irodori readiness、voice解決、固定合成probeがすべてpassした。SSH転送用LaunchAgentはmode
`0600`でrunning、loopbackだけで待ち受け、Irodori healthはmodel loadedを返した。

独立コードレビュー後、致命的停止中の合成結果が再生へ戻るrace、Control-C時の合成cancel、Speech
event buffer overflowの無通知drop、voice catalogの衝突、queue underrunの誤計上を局所修正した。
いずれも既存actorまたはdecode境界内の変更で、新しい常駐processや監視層は追加していない。

CoreAudio deviceの実行中hot-unplug監視と、URLSessionのtransport timeoutとは別のapp-level overall
deadlineは、このPoCには追加していない。前者はBlackHoleを実行中に削除・再構成した場合、後者は
接続先が少量のresponseを無期限に送り続けた場合に限る残余リスクである。通常のControl-Cはactive
requestをcancelし、以後の合成結果を再生しない。残余条件が実測で再現した時点で実装対象にする。

## 次の実験

低step化より先に、Apple Speechのfinalを待たず安定したpartial prefixだけを投機合成する価値がある。
ただし、発声済み音声は取り消せない。baselineのfinal-only経路を維持したまま、書き換え検出、投機結果の
破棄、segment間の音質、誤読率を別モードで測る必要がある。速度だけを見て既定経路へ昇格させない。
