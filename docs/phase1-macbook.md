# Phase 1: MacBook Pro (36GB, M3 Pro) — OpenAI Realtime互換ローカルサーバー

## ゴール

[VoiceInteractionAppSample](https://github.com/aRaikoFunakami/VoiceInteractionAppSample)
（Android Automotive, libwebrtc実装）から、OpenAIの実サーバーではなくローカルの
STT/LLM/TTSに接続する。LLM/STT/TTSは差し替え可能にする。

## 採用方針

`huggingface/speech-to-speech` の `--mode realtime` をそのまま使う。自作しない。
- WebRTC実装がOpenAI Realtime APIを模倣する設計（データチャネル名 `oai-events`、
  エンドポイント `POST /v1/realtime/calls` がクライアントのハードコード先と完全一致）
- `session.update` のパースはOpenAI公式Python SDKの型 (`openai.types.realtime.*`) を
  そのまま使っている → クライアントが送る `session.audio.input.turn_detection` の
  ネスト形式もそのまま通る
- STT/LLM/TTSは `backend_registry.py` でプラグイン化済み → CLIフラグで差し替え可能

## クライアント側の契約（調査結果）

- SDP交換: `POST https://api.openai.com/v1/realtime/calls` (Content-Type: application/sdp)
- セッション認証情報: `POST http://10.0.2.2:8787/api/realtime/session` (emulatorから見た
  ホストPCのアドレス) → `{clientSecret, expiresAt, sessionConfigVersion}` を期待。
- 日本語固定: `language: ja`, instructions は日本語の車載アシスタント想定。

**[VoiceInteractionAppSample#43](https://github.com/aRaikoFunakami/VoiceInteractionAppSample/issues/43)
で対応済み**: 設定画面（Settings > Apps > Default apps > Digital assistant app の歯車アイコン）
からOpenAI/ローカルを切り替えられる。`RealtimeServerSettings.kt` の実装は
このリポジトリのポート構成（broker=8787, calls=8765）とそのまま一致している。
ローカルモードで使う際はホストに `10.0.2.2`（AVD）またはこのMacのLAN IPを入力する。

## 重要な発見

- **Parakeet-TDT（`speech-to-speech`のデフォルトSTT）は日本語非対応**
  （`--parakeet_tdt_language` のhelpに「25 European languages」と明記）。
  日本語用STTには `--stt mlx-audio-whisper` を使うこと。
- Python 3.14ではなく **3.12 の venv** を使う（mlx系エコシステムの追随が速くないため）。
- `speech-to-speech[mlx-audio]` という extra は存在しない。`mlx`/`mlx-lm`/`mlx-audio` は
  Darwin向けにコア依存として既定で入る。追加が要るのは `webrtc` extra (aiortc) のみ。
- CLIの実際のサブコマンド構造はREADMEの記述と食い違う部分があった。信頼できるのは
  `speech-to-speech --help` の実出力。`--mac-optimal-settings` 相当は
  `--local_mac_optimal_settings` で、これは `--mode local`（ループバックのみ、
  ネットワーク非公開）を強制するため**今回の用途には使わない**。個別に
  `--stt` / `--llm_backend` / `--tts` / `--device` を指定する。
- WebRTCのSDPネゴシエーションで `ValueError: None is not in list` が出た場合は、
  オファーにオーディオtransceiverが無いことが原因（データチャネルのみのofferだと
  aiortc側がエラーになる）。実クライアントは音声transceiverを必ず追加しているので
  問題にならない。
- **`--enable_live_transcription`（デフォルトtrue）はSTT精度を壊す。必ず
  `--no_enable_live_transcription` を付けること。** デフォルトのままだと、VADが
  発話の完了を確認する前の最初の約0.88秒（`min_speech_ms`=384ms相当の窓）だけで
  STTを実行し、それを最終結果として確定→以降の音声を「stale」として破棄してしまう
  （`base_stt_handler`のログに`dropping stale STT input-after-final`と出る）。
  「これはテストです」(約1.2秒)を話しても「これは」で切れる、あるいは全く違う内容に
  ハルシネーションする（例:「ご視聴ありがとうございました」— Whisperの無音/短尺音声
  への定番ハルシネーション）。`--no_enable_live_transcription`を付けると、VADの
  `Speech soft-ended`→`Smart Turn: complete`を待ってから一度だけSTTが走るようになり、
  正しく認識される。実機（AAOS emulator + ホストMacマイク）で確認済み。
- 診断手法として、`STT/mlx_audio_whisper_handler.py`の`process()`冒頭に
  `S2S_DUMP_AUDIO_DIR`環境変数でWAVダンプするフックを一時的に追加すると、実際に
  Whisperへ渡っている音声を直接確認できる（venv内への一時パッチ、gitでは追跡されない）。
- **`Qwen3-4B`（bf16でも4bitでも）はfunction calling（tool call）を確実に発行できない。**
  ログの`Tools: []`は「toolsスキーマが未登録」ではなく「このターンでLLMが実際に
  ツール呼び出しを発行しなかった」の意味（`ctx.tools`＝出力から抽出された呼び出し結果。
  スキーマ自体は`session.tools`に正しく載っている）。4Bモデルは`open_youtube_search`を
  依頼されても平文で「検索します」と答えるだけでツール呼び出し用の特殊マーカー形式を
  出力しないことがある（プロンプトベースのtool-calling方式のため、小さいモデルほど
  形式追従が不安定）。`mlx-community/Qwen3.5-9B-4bit`に上げたところ確実に
  `ResponseFunctionToolCall(name='open_youtube_search', ...)`が発行されるようになった。
  レイテンシは伸びる（下記参照）。品質とレイテンシのトレードオフとして4Bではなく
  9Bを最低ラインにする。

## 起動コマンド（動作確認済み）

```bash
cd local_realtime_llm
source .venv/bin/activate  # Python 3.12 venv, `python3.12 -m venv .venv` で作成
speech-to-speech \
  --mode realtime \
  --device mps \
  --stt mlx-audio-whisper \
  --language ja \
  --no_enable_live_transcription \
  --llm_backend mlx-lm \
  --model_name mlx-community/Qwen3.5-9B-4bit \
  --tts qwen3 \
  --qwen3_tts_speaker ono_anna \
  --qwen3_tts_mlx_quantization bf16 \
  --ws_host 127.0.0.1 --ws_port 8765
```

起動ログの確認ポイント:
- `OpenAI Realtime API starting on ws://127.0.0.1:8765/v1/realtime`
- `Uvicorn running on http://127.0.0.1:8765`
- Qwen3-TTS warmup: TTFA ~1.7s, RTF ~0.87（実時間より速く生成できている）

ヘルスチェック:
```bash
curl -s http://127.0.0.1:8765/v1/pool
curl -s http://127.0.0.1:8765/v1/usage
```

## ブローカースタブ (`broker.py`)

`backend/local_broker.py` と同じ契約（`POST /api/realtime/session` →
`{clientSecret, expiresAt, sessionConfigVersion}`）を、OpenAIを呼ばずに返す
stdlib-onlyのスタブ。realtimeサーバー側は認証チェックをしないため、
`clientSecret` はダミー値でよい。

```bash
python3 broker.py   # 0.0.0.0:8787 で待受
```

⚠️ **注意**: このMacでは `~/AndroidStudioProjects/VoiceInteractionAppSample` の
本物の `local_broker.py`（実OpenAIキー使用）が既に8787番で常駐していたため、
作業時にkillして本スタブに差し替えた。実OpenAI経由での動作確認に戻したい場合は
本物のbroker.pyを再起動すること。

## WebRTC疎通確認

`aiortc` でSDP offer（音声transceiver + `oai-events`データチャネル必須）を作り
`/v1/realtime/calls` にPOSTし、`session.created` イベント受信を確認済み
（テストスクリプトは使い捨て、リポジトリには未保存）。

## 動作確認済みスタック（このMac向け）

| 項目 | 選定 |
|---|---|
| STT | `mlx-audio-whisper` (whisper-large-v3-turbo, MLX) |
| LLM | `mlx-lm` (`mlx-community/Qwen3.5-9B-4bit`) |
| TTS | `qwen3` (Qwen3-TTS-1.7B-CustomVoice, **bf16**, mlx-audio, speaker=`ono_anna`) |
| Transport | WebRTC (`/v1/realtime/calls`) / WebSocket (`/v1/realtime`) |

CustomVoiceモデルの話者一覧（`config.json`の`talker_config.spk_id`）:
`serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric, dylan`。
デフォルトの`aiden`は低めの男性声で「怖いお兄さん」という感想が出たため、
日本語アシスタント向けに`ono_anna`へ変更した（`--qwen3_tts_speaker`）。
TTS量子化も6bit→bf16に上げて音質改善を試みた（無料でできる改善、
それでもOpenAI TTSとの品質差は残る。12Hzコーデック自体の設計上の限界で、
speech-to-speechが対応する他の内蔵TTS（chatTTS/facebookMMS/pocket/kokoro）に
乗り換えても日本語で明確に上回る保証はない — 参考: [重要な発見]参照）。

LLMは`Qwen3-4B`から`Qwen3.5-9B-4bit`に変更（下記「重要な発見」参照:
4Bはtool callingが不安定なため）。

## 未完了 (Phase 1残タスク)

1. ~~`VoiceInteractionAppSample` のURLハードコードをローカルサーバーに向ける変更~~ →
   [#43](https://github.com/aRaikoFunakami/VoiceInteractionAppSample/issues/43) で対応済み
   （設定画面から切り替え可能に。PR #44, #45）。
2. ~~実機/エミュレータでの通しの動作確認~~ → **完了**（AAOS emulator
   `Automotive_1408p_landscape` + ホストMacマイク、設定画面でLOCAL/`10.0.2.2`を選択）。
   「これはテストです」と発話 → 正しく認識・応答・音声再生まで確認
   （`--no_enable_live_transcription`修正後）。
3. ~~発話終了から音声再生開始までのレイテンシ実測~~ → **完了**。実測値（キャッシュ済み・
   コールドスタートではない状態）:

   | 構成 | STT | LLM生成 | TTS TTFA | 発話終了→初回音声再生 |
   |---|---|---|---|---|
   | Qwen3-4B-bf16 | 約1.2s | 約3.2s (11 output tok) | 0.19s | **4.36s** |
   | Qwen3.5-9B-4bit + tool call | 約0.7s | 約4.1〜4.2s (29-34 output tok) | 0.26-0.32s | **4.5〜5.3s** |

   9Bはtool callingが確実になった分、LLM生成が長くなり総レイテンシも増えた
   （出力トークン数もtool呼び出し分だけ多い）。品質・確実性とレイテンシの
   トレードオフとして、4B→9Bへの切り替えは妥当と判断（現在の推奨構成）。
   Phase 2ではさらに大きいモデル（27B等）でこのトレードオフがどこまで
   成り立つか計測する。

4. **tool calling（function calling）動作確認 → 完了**。「YouTubeでフリーレンを
   検索して」で`open_youtube_search`ツールが実際に呼び出されることを実機ログで確認
   （`Tools: [ResponseFunctionToolCall(arguments='{"query": "フリーレン"}', ...)]`）。
   Qwen3-4Bでは同じ依頼に対しツール呼び出しを発行せず平文で応答するだけだった
   （「重要な発見」参照）。

## Phase 2 (予定): Mac Studio 256GB

同じ構成を `--host 0.0.0.0` でMac Studio上に展開し、LLMを大きいサイズ
（Qwen3.5-27B等、現在のMacBook Pro側の基準値=Qwen3.5-9B-4bitとの比較）に
差し替えて同じレイテンシ計測をやり直す。
