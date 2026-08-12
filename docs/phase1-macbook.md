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
  → `RealtimeWebRtcClient.kt` にハードコード。ローカルサーバーに向けるには
  ここを書き換える必要がある（**未着手、Phase 1残タスク**）。
- セッション認証情報: `POST http://10.0.2.2:8787/api/realtime/session` (emulatorから見た
  ホストPCのアドレス) → `{clientSecret, expiresAt, sessionConfigVersion}` を期待。
  `HttpRealtimeCredentialProvider` はbrokerUrlを注入できる設計なので、ここは素直に
  差し替え可能。
- 日本語固定: `language: ja`, instructions は日本語の車載アシスタント想定。

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

## 起動コマンド（動作確認済み）

```bash
cd local_realtime_llm
source .venv/bin/activate  # Python 3.12 venv, `python3.12 -m venv .venv` で作成
speech-to-speech \
  --mode realtime \
  --device mps \
  --stt mlx-audio-whisper \
  --language ja \
  --llm_backend mlx-lm \
  --model_name mlx-community/Qwen3-4B-Instruct-2507-bf16 \
  --tts qwen3 \
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
| TTS | `qwen3` (Qwen3-TTS-1.7B-CustomVoice, 6bit, mlx-audio) |
| Transport | WebRTC (`/v1/realtime/calls`) / WebSocket (`/v1/realtime`) |

## 未完了 (Phase 1残タスク)

1. `VoiceInteractionAppSample` の `RealtimeWebRtcClient.kt` 内のURLハードコード
   （`https://api.openai.com/v1/realtime/calls`）をローカルサーバーのURLに向ける変更。
2. 実機/エミュレータでの通しの動作確認（発話→STT→LLM→TTS→再生）。
3. 発話終了から音声再生開始までのレイテンシ実測。

## Phase 2 (予定): Mac Studio 256GB

同じ構成を `--host 0.0.0.0` でMac Studio上に展開し、LLMを大きいサイズ
（Qwen3.5-9B等）に差し替えて同じレイテンシ計測をやり直す。
