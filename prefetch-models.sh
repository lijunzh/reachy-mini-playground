#!/usr/bin/env bash
#
# Pre-download everything fetched from the Hugging Face Hub at runtime: the
# speech-to-speech VAD/STT/TTS weights, plus the emotion and dance libraries the
# conversation app's play_emotion and dance tools pull on first use.
#
# Optional on an unrestricted network (both are fetched on demand), but behind
# a restrictive proxy those fetches are slow and occasionally stall, and a stall
# is fatal mid-conversation. Downloading up front is resumable and idempotent:
# re-run it until it reports OK for everything.
#
# Needs no proxy: without a proxy.env file it runs with settings tuned for an
# unrestricted network.
#
set -euo pipefail
cd "$(dirname "$0")"

VENV="s2s_venv"
ATTEMPTS="${ATTEMPTS:-5}"

[ -x "./$VENV/bin/python" ] || {
    echo "error: $VENV missing. Run ./setup-local-backend.sh first." >&2; exit 1; }

# shellcheck disable=SC1091
if [ -f proxy.env ]; then
    . ./proxy.env
    PROXIED=1
else
    PROXIED=0
fi

# Defaults below suit an unrestricted network. proxy.env's presence is the
# signal to fall back to slower, more conservative settings, so nobody outside
# the corporate network inherits workarounds they do not need.
if [ "$PROXIED" = "1" ]; then
    # The proxy is slow to first byte on large blobs.
    export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-60}"
    export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-120}"
    # snapshot_download's default 8 workers get rate-limited into a mix of 403s,
    # 502s and dropped connections on repos with many files.
    WORKERS="${WORKERS:-1}"
else
    WORKERS="${WORKERS:-8}"
fi

exec "./$VENV/bin/python" - "$ATTEMPTS" "$WORKERS" "$PROXIED" <<'PY'
import sys, time
from huggingface_hub import hf_hub_download, snapshot_download

attempts, workers = int(sys.argv[1]), int(sys.argv[2])
proxied = sys.argv[3] == "1"

# The emotions library's 84 .ogg sound effects live on a CDN path the corporate
# gateway blocks with a 403, while its 88 motion files download fine. Behind the
# proxy, take the motions alone so emotions play silently rather than failing;
# everywhere else take the whole repo, audio included.
EMOTION_PATTERNS = ["*.json", "*.jsonl", "*.md", ".gitattributes"] if proxied else None

# (label, repo, filename or None for the whole snapshot, repo_type, allow_patterns)
TARGETS = [
    ("VAD      Smart Turn v3", "pipecat-ai/smart-turn-v3",
     "smart-turn-v3.2-cpu.onnx", "model", None),
    ("STT      Parakeet TDT", "mlx-community/parakeet-tdt-0.6b-v3",
     None, "model", None),
    ("TTS      Qwen3-TTS", "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit",
     None, "model", None),
    ("EMOTION  library", "pollen-robotics/reachy-mini-emotions-library",
     None, "dataset", EMOTION_PATTERNS),
    ("DANCE    library", "pollen-robotics/reachy-mini-dances-library",
     None, "dataset", None),
]

failed = []
for label, repo, filename, repo_type, allow in TARGETS:
    for attempt in range(1, attempts + 1):
        try:
            if filename:
                hf_hub_download(repo, filename, repo_type=repo_type)
            else:
                snapshot_download(repo, repo_type=repo_type,
                                  max_workers=workers, allow_patterns=allow)
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
    if not proxied and any("EMOTION" in f for f in failed):
        # Most likely cause when the motion files are already cached: the .ogg
        # sound effects are being refused, which is what a restrictive network
        # does. proxy.env switches this repo to motions only.
        print("\nIf you are behind a restrictive proxy, copy proxy.env.example to"
              "\nproxy.env and re-run: the emotions library then skips the sound"
              "\neffects, which are the files such networks tend to block.")
    sys.exit(1)
print("\nAll assets cached. Start the server: ./run-local-backend.sh")
PY
