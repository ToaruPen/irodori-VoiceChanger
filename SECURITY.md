# Security

## 保護対象

このPoCはマイク音声と文字起こしを一時的に処理しますが、入力音声、生成音声、partial/final
transcriptを保存しません。telemetryはローカルのbounded JSONLだけで、本文、voice、device、
endpoint、credentialを含みません。外部telemetry exporterはありません。

## 接続境界

- Irodori URLに埋め込まれたuser infoを拒否します。
- HTTPは数値loopbackだけ、remote endpointはHTTPSだけを許可します。
- capabilitiesのvoice IDとruntime generationを合成要求へ相関させます。
- Irodori streamとWAVはframe数、byte数、duration、format上限を検証してから再生します。
- 選択したCoreAudio deviceが失われても、既定deviceへ暗黙fallbackしません。
- TCC database、Irodori service、voice bank、Discord設定を自動変更しません。

## 利用者が守ること

headphoneを使い、生成音声がマイクへ回り込むdevice構成を避けてください。voiceの使用許可と
Discord等の利用規約を確認してください。設定、telemetry、再現用音声を公開Issueへ添付しないで
ください。

## 脆弱性の報告

秘密情報や音声を公開Issueへ投稿せず、GitHub Security Advisoriesを使用してください。再現条件、
OS/Xcode version、stable error codeを含め、host、device、voice、transcriptは削除してください。
