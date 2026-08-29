#!/usr/bin/env bash
#
# Pre-download the VAD/STT/TTS weights speech-to-speech needs at startup.
#
# Optional on an unrestricted network (the server fetches them itself), but
# behind the proxy the fetch is slow and occasionally stalls, and a stall during
# startup kills the server. Downloading up front is resumable and idempotent:
# re-run it until it reports OK for everything.
#
set -euo pipefail
cd "$(dirname "$0")"

VENV="s2s_venv"
ATTEMPTS="${ATTEMPTS:-5}"

[ -x "./$VENV/bin/python" ] || {
    echo "error: $VENV missing. Run ./setup-local-backend.sh first." >&2; exit 1; }

# shellcheck disable=SC1091
[ -f proxy.env ] && . ./proxy.env

# Long timeouts: the proxy is slow to first byte on large blobs.
export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-60}"
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-120}"

exec "./$VENV/bin/python" - "$ATTEMPTS" <<'PY'
import sys, time
from huggingface_hub import hf_hub_download, snapshot_download

attempts = int(sys.argv[1])

# (label, repo, filename or None for whole snapshot)
TARGETS = [
    ("VAD  Smart Turn v3", "pipecat-ai/smart-turn-v3", "smart-turn-v3.2-cpu.onnx"),
    ("STT  Parakeet TDT",  "mlx-community/parakeet-tdt-0.6b-v3", None),
    ("TTS  Qwen3-TTS",     "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit", None),
]

failed = []
for label, repo, filename in TARGETS:
    for attempt in range(1, attempts + 1):
        try:
            if filename:
                hf_hub_download(repo, filename)
            else:
                snapshot_download(repo)
            print(f"OK    {label}  ({repo})", flush=True)
            break
        except Exception as exc:
            reason = f"{type(exc).__name__}: {exc}"[:110]
            if attempt == attempts:
                print(f"FAIL  {label}  {reason}", flush=True)
                failed.append(label)
            else:
                # Resumable: each retry picks up where the last left off.
                print(f"  retry {attempt}/{attempts - 1} {label}  {reason}", flush=True)
                time.sleep(3)

if failed:
    print(f"\n{len(failed)} incomplete. Re-run to resume: " + ", ".join(failed))
    sys.exit(1)
print("\nAll weights cached. Start the server: ./run-local-backend.sh")
PY
