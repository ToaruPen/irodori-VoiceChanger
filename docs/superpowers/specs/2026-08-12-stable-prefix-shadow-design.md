# Stable Partial Prefix Shadow PoC 設計

**Status:** Approved for implementation
**Date:** 2026-08-12

## 目的

実マイクのbaselineでは、音声range終端からApple Speechのfinal deliveryまで約2.1秒を要した一方、
first partialは約30–100msで届いた。この差に短縮余地はある。ただしpartialを先に合成して誤れば、
すでに再生した音声を取り消せない。

最初のPoCは音声経路を変えない。Apple Speechのpartialからstable prefix候補を計算し、候補が立った
時刻、後続partialによるrewriteとrollback、finalとの一致度だけを記録する。Irodoriへ送る本文は従来どおり
finalのみとし、生成音声とCoreAudio出力にも変更を加えない。

## 成功条件

1. `stable_prefix`設定時だけshadow評価が有効になり、`final_only`の挙動は変わらない。
2. 同じWAVをreplayし、候補の先行時間、候補が得られた発話数、rewrite、rollback、final一致率を
   本文なしのtelemetryで比較できる。
3. shadow評価中もpartialからIrodori request、音声生成、再生enqueueが発生しない。
4. 固定KPIは置かず、同一WAV・同一条件で一変数ずつ比較する。

## 非目標

- partialまたはstable prefix候補のIrodori送信
- 投機合成、投機音声の保存、再生、cache
- segment結合、発音済み音声の訂正、既定modeの変更
- ASR backend、Speech.framework設定、Irodori sampling profileの同時変更

## Stable prefix判定

比較単位はSwiftの`Character`とし、前後の空白と改行を除いたpartialをメモリ内だけで扱う。
各文字位置について、同じ文字が同じ位置で連続観測された回数と最初の観測時刻を保持する。
途中の文字が変わった位置以降は観測状態を破棄し、そこで安定時間を数え直す。

先頭から連続して次の両条件を満たした範囲をstable prefix候補とする。

- `minimum_observations`回以上、同じ位置で観測された
- 最初の観測から`minimum_stable_milliseconds`以上経過した

単純な末尾追加はrewriteに数えない。前回partialが現在partialのprefixでなくなった場合をrewrite、
その変更がすでに観測済みのstable prefix候補へ及んだ場合をrollbackとする。final受信時にも候補との
longest common prefixを比較し、候補内一致率とfinal coverage率を算出する。

## データフロー

`StablePrefixShadowMonitor`は発話IDごとに小さなevaluatorを保持する。`VoiceChangerPipeline`と
synthesisなしreplayの双方が同じmonitorへ`SpeechEvent`を渡す。monitorが返すのはshadow telemetry
だけであり、合成queueや再生queueへの参照を持たない。

`final_only`ではmonitorを生成しない。`stable_prefix`でもpipelineのcommit処理はfinal eventだけを
受け付ける。この分離をunit testで固定する。

## Telemetryとreport

追加eventは次の4種類に限定する。

- `shadow_prefix_candidate`: stable prefix候補が初めて立つ、または前方へ伸びた
- `shadow_prefix_rewrite`: 前回partialのprefixでないpartialを観測した
- `shadow_prefix_rollback`: rewriteまたはfinalが既存候補へ及んだ
- `shadow_final_comparison`: final到着時の比較結果

永続化する追加値は候補の有無、0–1の候補一致率、0–1のfinal coverage率だけである。比率は正確な
文字数比を復元しにくい0.1刻みへ丸める。本文、文字数、hash、partial、final、WAV pathは保存しない。
reportは候補発話数、rewrite/rollback数、
speech startから最初の候補まで、最初の候補からfinalまでの先行時間、一致率とcoverage率の
min/p50/p95/maxを返す。

## 検証

純粋evaluatorをfake timestampでTDDし、末尾追加、suffix rewrite、候補範囲内rewrite、final不一致を
決定的に再現する。次にpipeline testでpartialが合成を開始しないことを確認する。ローカルgate通過後、
同一の固定PCM16 WAVを`final_only`と`stable_prefix`でreplayする。

最初の実測では既定の3 observations / 400msだけを評価する。候補が十分に観測され、rollbackが
発生しないか低い場合に限り、安定時間または観測回数のどちらか一方だけを次の比較で変更する。
投機合成へ進む判断は、このshadow実測とは別の次段として扱う。
