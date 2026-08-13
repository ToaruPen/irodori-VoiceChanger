# 公開README改訂設計

## 目的

公開リポジトリを初めて訪れた利用者が、Irodori VoiceChangerの用途、現在の成熟度、必要環境、
安全な既定動作、導入手順、実験機能の限界を英語で短時間に理解できるREADMEへ改訂する。
実装済みの契約だけを記載し、研究結果の詳細は検証文書へ委ねる。

## 想定読者

- Apple Silicon Macで日本語のリアルタイム音声変換を試したい利用者
- Apple Speech、Irodori-TTS、CoreAudio間の遅延を再現可能に評価したい開発者
- shadow実験の安全境界とprivacy方針を確認したいcontributor

## 構成

README本文は英語で、次の順に構成する。

1. 一文の概要とexperimental status
2. 現在の音声経路と、final-onlyである既定動作
3. 主な機能と明示的な非目標
4. 必要環境
5. Quick Startと設定項目
6. live実行、WAV replay、reportの基本操作
7. shadow実験の比較表と、出力へ影響しない境界
8. privacy、failure、CoreAudio routingの注意点
9. 検証済み事実と既知の限界
10. 開発用quality gate、文書、license

## 情報の分離

READMEには利用判断に必要な結論だけを残す。個別session ID、全percentile、実験の時系列、実装計画は
`docs/validation/`と`docs/superpowers/`へリンクする。公開READMEを内部作業日誌にはしない。

stable prefix、固定無音endpoint、Apple early finalize、Smart Turnは「experimental shadow modes」として
一つの表へ集約する。各modeについて、利用可能なcommand、観測対象、外部出力への影響を明記する。
Smart TurnはASRではなくendpoint classifierであり、live active finalizeを提供しないことを明示する。

## 正確性と安全境界

- 通常経路はApple SpeechのfinalだけをIrodoriへ送り、生成音声を選択したCoreAudio出力へ流す。
- shadow機能は明示的なflagがない限り動作しない。
- `--shadow-early-finalize-ms`だけはreplay内でAppleのfinalize APIを呼ぶが、合成・再生は行わない。
- telemetryへtranscript、音声、voice ID、device ID、URL、資格情報を保存しない。
- 出力deviceが見つからない場合にMacの既定speakerへfallbackしない。
- Irodori serverの再起動、再配備、voice bank変更を行わない。

## 文体

技術的だが製品利用者向けの平易な英語を使う。誇大な低遅延表現や未達の品質保証を避ける。
コマンドはcopy-paste可能にし、同じ説明を複数節へ重複させない。

## 検証

- README内のcommandとoptionを`justfile`およびCLI parserと照合する。
- 設定例を`config/irodori-voicechanger.example.json`と照合する。
- 実験結果を保存済みvalidation文書と照合する。
- `rg`で日本語本文、旧active flag、placeholder、重複headingを検査する。
- 最終的に`just check`と`git diff --check`を実行する。
