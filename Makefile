RUN_DIR := .run
BROKER_PID := $(RUN_DIR)/broker.pid
SERVER_PID := $(RUN_DIR)/server.pid
BROKER_LOG := $(RUN_DIR)/broker.log
SERVER_LOG := $(RUN_DIR)/server.log

.PHONY: setup down logs status

# Note: the guard + launch below must be one shell invocation (all `\`
# continuations under a single `@if`), not separate recipe lines. Each
# Makefile recipe line runs in its own shell, so `exit 0` on its own line
# only exits that line's subshell and Make falls through to the next line
# regardless -- this bit us once (double launch). This also has to work
# under macOS's stock /usr/bin/make (GNU Make 3.81), which predates
# .ONESHELL (3.82+), so that fix isn't available either.
setup:
	@mkdir -p $(RUN_DIR)
	@if [ -f $(SERVER_PID) ] && kill -0 $$(cat $(SERVER_PID)) 2>/dev/null; then \
		echo "already running (server pid $$(cat $(SERVER_PID)), broker pid $$(cat $(BROKER_PID) 2>/dev/null))"; \
	else \
		uv sync; \
		uv run python broker.py > $(BROKER_LOG) 2>&1 & echo $$! > $(BROKER_PID); \
		uv run speech-to-speech \
			--mode realtime --device mps \
			--stt mlx-audio-whisper --language ja --no_enable_live_transcription \
			--llm_backend mlx-lm --model_name mlx-community/Qwen3.5-9B-4bit \
			--tts qwen3 \
			--qwen3_tts_model_name Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
			--qwen3_tts_speaker ono_anna \
			--qwen3_tts_mlx_quantization bf16 \
			--qwen3_tts_non_streaming_mode True \
			--ws_host 127.0.0.1 --ws_port 8765 \
			> $(SERVER_LOG) 2>&1 & echo $$! > $(SERVER_PID); \
		echo "waiting for speech-to-speech on :8765 (model load, first run can take minutes)..."; \
		i=0; until curl -sf http://127.0.0.1:8765/v1/usage >/dev/null 2>&1 || [ $$i -ge 300 ]; do sleep 2; i=$$((i+1)); done; \
		if curl -sf http://127.0.0.1:8765/v1/usage >/dev/null 2>&1; then \
			echo "up: broker pid $$(cat $(BROKER_PID)) (:8787), server pid $$(cat $(SERVER_PID)) (:8765)"; \
		else \
			echo "server did not come up within timeout, see $(SERVER_LOG)"; exit 1; \
		fi; \
	fi

down:
	@-[ -f $(SERVER_PID) ] && kill $$(cat $(SERVER_PID)) 2>/dev/null; rm -f $(SERVER_PID)
	@-[ -f $(BROKER_PID) ] && kill $$(cat $(BROKER_PID)) 2>/dev/null; rm -f $(BROKER_PID)
	@echo "stopped"

logs:
	tail -f $(BROKER_LOG) $(SERVER_LOG)

status:
	@curl -s http://127.0.0.1:8765/v1/usage || echo "server not responding"
	@curl -s -X POST http://127.0.0.1:8787/api/realtime/session -d '{}' || echo "broker not responding"
