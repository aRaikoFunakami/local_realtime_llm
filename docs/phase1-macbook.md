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
  --model_name mlx-community/Qwen3-4B-Instruct-2507-bf16 \
  --tts qwen3 \
  --qwen3_tts_speaker ono_anna \
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
| LLM | `mlx-lm` (`mlx-community/Qwen3-4B-Instruct-2507-bf16`) |
| TTS | `qwen3` (Qwen3-TTS-1.7B-CustomVoice, 6bit, mlx-audio, speaker=`ono_anna`) |
| Transport | WebRTC (`/v1/realtime/calls`) / WebSocket (`/v1/realtime`) |

CustomVoiceモデルの話者一覧（`config.json`の`talker_config.spk_id`）:
`serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric, dylan`。
デフォルトの`aiden`は低めの男性声で「怖いお兄さん」という感想が出たため、
日本語アシスタント向けに`ono_anna`へ変更した（`--qwen3_tts_speaker`）。

## 未完了 (Phase 1残タスク)

1. ~~`VoiceInteractionAppSample` のURLハードコードをローカルサーバーに向ける変更~~ →
   [#43](https://github.com/aRaikoFunakami/VoiceInteractionAppSample/issues/43) で対応済み
   （設定画面から切り替え可能に。PR #44, #45）。
2. ~~実機/エミュレータでの通しの動作確認~~ → **完了**（AAOS emulator
   `Automotive_1408p_landscape` + ホストMacマイク、設定画面でLOCAL/`10.0.2.2`を選択）。
   「これはテストです」と発話 → 正しく認識・応答・音声再生まで確認
   （`--no_enable_live_transcription`修正後）。
3. ~~発話終了から音声再生開始までのレイテンシ実測~~ → **完了**。実測値（1ターン、
   Qwen3-4B-bf16、キャッシュ済み・コールドスタートではない状態）:

   | 区間 | 時間 |
   |---|---|
   | STT（VAD soft-end→transcription、MLXロック待ち含む） | 約1.2s |
   | LLM生成（573 input tokens→11 output tokens） | 約3.2s |
   | TTS初回音声チャンク（TTFA） | 0.19s |
   | **発話終了→初回音声再生（サーバー計測 "last speech detected to first speech out"）** | **4.36s** |

   ボトルネックはLLM生成（3.2s）。bf16の4Bモデルはこの用途には遅めで、
   毎ターンのプロンプト再処理（システムプロンプト+tools schema、573トークン）が
   効いている。体感速度を優先するなら4bit量子化モデルへの切り替えを検討する
   （Phase 2でも同様に計測して比較する）。

## Phase 2 (予定): Mac Studio 256GB

同じ構成を `--host 0.0.0.0` でMac Studio上に展開し、LLMを大きいサイズ
（Qwen3.5-9B等）に差し替えて同じレイテンシ計測をやり直す。
