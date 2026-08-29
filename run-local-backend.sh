#!/usr/bin/env bash
#
# Start the local speech-to-speech realtime server. Must be running before the
# daemon and conversation app. Reads LLM settings from local-backend.conf.
#
set -euo pipefail
cd "$(dirname "$0")"

# Defaults; override in local-backend.conf (gitignored, machine-specific).
LLM_MODEL="qwen/qwen3.8-27b"
LLM_BASE_URL="http://127.0.0.1:1234/v1"
LLM_API_KEY="lm-studio"
# responses-api (LM Studio) or chat-completions (omlx, mlx_lm.server).
LLM_BACKEND="responses-api"
WS_HOST="127.0.0.1"
WS_PORT="8765"
STT="parakeet-tdt"
TTS="qwen3"
# shellcheck disable=SC1091
[ -f local-backend.conf ] && . ./local-backend.conf
# Proxy + CA settings, only present behind a TLS-intercepting proxy.
# shellcheck disable=SC1091
[ -f proxy.env ] && . ./proxy.env

[ -x ./s2s_venv/bin/speech-to-speech ] || {
    echo "error: s2s_venv missing. Run ./setup-local-backend.sh first." >&2; exit 1; }

# The LLM server must implement the Responses API (/v1/responses), not just
# chat completions. LM Studio does; mlx_lm.server does not.
if ! curl -sf -m 5 "${LLM_BASE_URL%/v1}/v1/models" >/dev/null 2>&1; then
    echo "error: no OpenAI-compatible server at $LLM_BASE_URL" >&2
    echo "       Start LM Studio and load $LLM_MODEL, then retry." >&2
    exit 1
fi

echo "==> LLM  : $LLM_MODEL via $LLM_BASE_URL  (backend=$LLM_BACKEND)"
echo "==> serve: ws://$WS_HOST:$WS_PORT/v1/realtime  (stt=$STT tts=$TTS)"
echo "    First run downloads ~2.5 GB of weights. Wait for:"
echo "    'OpenAI Realtime API starting on ws://$WS_HOST:$WS_PORT/v1/realtime'"

# --responses_api_disable_thinking sends chat_template_kwargs.enable_thinking=false.
# vLLM-style servers honour it; LM Studio's llama.cpp backend ignores it, so a
# reasoning model still reasons (measured: 180 of 211 tokens, 15.2s per turn) and
# the turn gets cancelled before it finishes. Use an instruct model instead.
# See README, "Troubleshooting: Reachy never answers".
exec ./s2s_venv/bin/speech-to-speech \
    --llm_backend "$LLM_BACKEND" \
    --model_name "$LLM_MODEL" \
    --responses_api_base_url "$LLM_BASE_URL" \
    --responses_api_api_key "$LLM_API_KEY" \
    --responses_api_disable_thinking \
    --stt "$STT" --tts "$TTS" \
    --ws_host "$WS_HOST" --ws_port "$WS_PORT"
