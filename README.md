# local_realtime_llm

**OpenAI Realtime API（WebRTC）互換のローカルサーバー。** STT/LLM/TTSはすべて
Apple Silicon上でローカル推論し、外部APIには一切依存しない。

[VoiceInteractionAppSample](https://github.com/aRaikoFunakami/VoiceInteractionAppSample)
（Android Automotive, `VoiceInteractionService`実装）から実機/エミュレータで接続し、
発話→STT→LLM→TTS→再生の一連の流れをエンドツーエンドで確認済み
（詳細は[docs/phase1-macbook.md](docs/phase1-macbook.md)）。

## できること

- クライアントからは**OpenAIのRealtime API（WebRTC）と同じ契約**に見える
  （`POST /v1/realtime/calls`、SDP offer/answer、`oai-events`データチャネル、
  `session.update`/`session.updated`/`response.*`イベント）。クライアント側の
  コードはOpenAI公式エンドポイントを叩くつもりで書いたものがそのまま動く。
- **STT / LLM / TTSはすべて差し替え可能**（CLIフラグ一つ）。今回はMLX
  （Apple Silicon）バックエンドを使い、モデル・GPUとも全部このMac上で動く。
- **function calling（tool call）も動く**。クライアントがセッションに登録した
  ツール（例: YouTube検索）をLLMが実際に呼び出し、`response.function_call_arguments.done`
  相当のイベントで結果を返す一連の往復を確認済み。

## 構成

自作のWebRTCサーバーではなく、[huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech)
の`--mode realtime`をそのまま使う。理由:

- WebRTC実装がOpenAI Realtime APIを模倣する設計（データチャネル名`oai-events`、
  エンドポイント`POST /v1/realtime/calls`が完全一致）
- `session.update`のパースにOpenAI公式Python SDKの型定義をそのまま使っている
- STT/LLM/TTSがバックエンド登録制でプラグイン化されている → 差し替えは
  CLIフラグの変更だけで済む

```text
Android/VoiceInteractionAppSample (client)
        │  WebRTC (SDP + oai-events data channel)
        ▼
this repo: broker.py (credential stub, :8787)
        +
speech-to-speech --mode realtime (:8765)
        ├── VAD:  Silero VAD v5 + Smart Turn v3.2
        ├── STT:  mlx-audio-whisper (whisper-large-v3-turbo, MLX)
        ├── LLM:  mlx-lm (Qwen3.5-9B-4bit)
        └── TTS:  qwen3 (Qwen3-TTS-1.7B-CustomVoice, mlx-audio)
```

## セットアップ

```bash
python3.12 -m venv .venv   # mlx系エコシステムの追随が速くないため3.14ではなく3.12を使う
source .venv/bin/activate
pip install "speech-to-speech[webrtc]"   # mlx/mlx-lm/mlx-audioはDarwinのコア依存に含まれる
```

## 起動

```bash
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

別ターミナルでセッションブローカー（クライアントの認証情報取得先スタブ）を起動:

```bash
python3 broker.py   # 0.0.0.0:8787
```

ヘルスチェック:

```bash
curl -s http://127.0.0.1:8765/v1/pool
curl -s http://127.0.0.1:8765/v1/usage
```

クライアント（VoiceInteractionAppSample）側は設定画面でLOCALモードを選び、
ホストにこのMacのアドレス（AVDなら`10.0.2.2`、実機なら同一LAN上のIP）を入れる。

## 動作確認済みスタック

| 項目 | 選定 |
|---|---|
| VAD | Silero VAD v5 + Smart Turn v3.2 |
| STT | `mlx-audio-whisper`（whisper-large-v3-turbo, MLX、日本語対応） |
| LLM | `mlx-lm`（`mlx-community/Qwen3.5-9B-4bit`） |
| TTS | `qwen3`（Qwen3-TTS-1.7B-CustomVoice, bf16, mlx-audio, speaker=`ono_anna`） |
| Transport | WebRTC (`/v1/realtime/calls`) / WebSocket (`/v1/realtime`) |

発話終了→初回音声再生: 約4.5〜5.3秒（内訳・トレードオフの詳細は
[docs/phase1-macbook.md](docs/phase1-macbook.md)）。

## ハマりどころ（詳細はdocs/参照）

- デフォルトSTT（Parakeet-TDT）は日本語非対応 → `mlx-audio-whisper`を使う
- `--enable_live_transcription`（デフォルトON）は発話の途中でSTTを確定してしまい
  認識が壊れる → `--no_enable_live_transcription`必須
- 小さいLLM（Qwen3-4B）はtool callingを確実に発行できない → 9B以上を使う
- ローカルTTS（Qwen3-TTS）はOpenAI TTSと同水準の音質にはならない
  （コーデック設計上の限界。量子化を上げる程度の改善は可能）

一つずつの根本原因・調査過程は[docs/phase1-macbook.md](docs/phase1-macbook.md)に
すべて記録している。

## 今後

Mac Studio (256GB) を推論サーバーにして、より大きいLLM（Qwen3.5-27B等）での
品質・レイテンシのトレードオフを比較する（Phase 2、未着手）。
