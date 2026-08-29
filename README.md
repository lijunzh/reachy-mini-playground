# Reachy Mini — simulator dev environment

Local development against the [Reachy Mini](https://huggingface.co/docs/reachy_mini) MuJoCo
simulator. No physical robot required: in sim the daemon presents itself as a Reachy Mini
Lite on `localhost`, so SDK scripts run unmodified on real hardware later.

**macOS (Apple Silicon) only.** The scripts refuse to run elsewhere: `mjpython` needs a
macOS-specific dylib fix, and the local conversation backend pulls MLX, which has no Intel
build. Python 3.12, `reachy-mini` 1.10.0rc5, `mujoco` 3.3.0.

## Setup

On a fresh macOS machine, install [uv](https://docs.astral.sh/uv/) and Git LFS, then run
the setup script — it creates the venv, installs everything, applies both macOS fixes
below, and verifies the result. It is idempotent, so re-running it is safe.

```bash
brew install git git-lfs
curl -LsSf https://astral.sh/uv/install.sh | sh

git clone https://github.com/lijunzh/reachy-mini-playground.git
cd reachy-mini-playground
./setup.sh
```

Pass `--locked` to install the exact transitive versions from
`requirements.lock.txt` instead of resolving fresh.

### Reproducing the whole setup elsewhere

Nothing large is committed. Each layer is a pinned manifest plus a script:

| Layer | Manifest | Script | Size |
| --- | --- | --- | --- |
| Simulator env | `requirements.txt` / `requirements.lock.txt` | `./setup.sh` | 1.4 GB |
| Conversation app | pinned inside the script (`mcp==1.29.0`) | `./install-app.sh` | 1.3 GB |
| Local backend | `requirements-s2s.txt` / `requirements-s2s.lock.txt` | `./setup-local-backend.sh` | 1.7 GB + 2.5 GB weights |

Full sequence on a new machine with internet access:

```bash
./setup.sh                                    # 1. simulator env
./setup-local-backend.sh                      # 2. speech-to-speech (skip if using the cloud backend)
cp .env.example .env                          # 3. point the app at the local backend
cp local-backend.conf.example local-backend.conf   # 4. set your LLM model / URL

./run-local-backend.sh                        # 5. terminal A: realtime server
./reachy_mini_env/bin/mjpython -m reachy_mini.daemon.app.main --sim --desktop-app-daemon  # terminal B
./install-app.sh                              # 6. terminal C: install the app (daemon must be up)
curl -X POST http://127.0.0.1:8000/api/apps/start-app/reachy_mini_conversation_app
```

Machine-specific files (`.env`, `local-backend.conf`) are gitignored; copy them
from the `.example` versions. Skip steps 2, 4, and 5 to use the hosted Hugging
Face backend instead.

The venv is deliberately not in git: it is 1.4 GB, macOS/arm64-only, and hardcodes
absolute paths in its console-script shebangs and `pyvenv.cfg`, so a copied venv breaks on
any other machine. `requirements.txt` plus this script is the reproducible part.

<details>
<summary>Manual equivalent, if you prefer not to run the script</summary>

```bash
uv venv reachy_mini_env --python 3.12 --seed
./reachy_mini_env/bin/pip install -r requirements.txt
```

Use `pip` from inside the venv rather than `uv pip` — the upstream docs warn that uv has
compatibility issues with MuJoCo on macOS. Then apply both fixes below.

</details>

### macOS fix required after creating the venv

`mjpython` needs a shared `libpython3.12.dylib`, which uv's standalone CPython does not
expose where mjpython's rpath looks. Without this symlink mjpython will not start at all,
failing with `Library not loaded: @rpath/libpython3.12.dylib`:

```bash
ln -sfn "$(./reachy_mini_env/bin/python -c 'import sysconfig,pathlib; print(pathlib.Path(sysconfig.get_config_var("installed_base"))/"lib"/"libpython3.12.dylib")')" \
        reachy_mini_env/libpython3.12.dylib
```

Optional, from the upstream troubleshooting guide: the bundled `libgstpython.dylib` fails
to load (same rpath problem). Renaming it silences the error at no cost to functionality.

```bash
mv reachy_mini_env/lib/python3.12/site-packages/gstreamer_python/lib/gstreamer-1.0/libgstpython{,_}.dylib
```

## Running

```bash
source reachy_mini_env/bin/activate
mjpython -m reachy_mini.daemon.app.main --sim
```

On macOS the `mjpython` launcher is required; plain `reachy-mini-daemon --sim` will not
drive the GUI correctly. Add `--scene minimal` for a table with objects (apple, croissant,
duck), or `--headless` to run with no viewer window.

**Backgrounding the daemon requires `--headless`.** `mjpython` needs the main thread for
the MuJoCo viewer, so `nohup mjpython ... --sim &` dies with `Segmentation fault: 11`.
Either run it in the foreground with a viewer, or background it headless.

**Startup takes 50–90 seconds.** GStreamer rescans its plugin registry in-process on every
launch and no cache is persisted. It is not hung — wait for:

```
reachy_mini.daemon.daemon - INFO - Daemon started successfully.
uvicorn.error - INFO - Uvicorn running on http://127.0.0.1:8000
```

Then verify with `python hello_sim.py` — the head should tilt and rise and the antennas
wiggle in the viewer.

## Notes

Harmless log messages in simulation:

| Message | Why |
| --- | --- |
| `No Reachy Mini Audio USB device found!` | The USB audio card does not exist in sim |
| `No hardware AEC; enabled software echo cancellation` | XMOS is hardware-only; GStreamer `webrtcdsp` substitutes |
| `External plugin loader failed` (GStreamer) | Cosmetic; it is why startup is slow |
| `IK error: Collision detected or head pose not achievable!` | The upstream example pose triggers this; motion still executes |

**~63 MB/s of loopback traffic is expected.** The simulated camera renders 1280x720 RGB at
25 fps and sends it *uncompressed* over UDP to `localhost:5005` for the WebRTC media server
(`1280 x 720 x 3 x 25 = 69 MB/s`). It never touches a real network interface. `--no-media`
does *not* stop it; only `--headless` does, since the camera thread is gated on the viewer.

**Do not name your own package `reachy_mini`.** A `reachy_mini/` directory or
`reachy_mini.py` file in the working directory shadows the installed SDK and breaks imports.

## Fully local backend (no cloud)

By default the conversation app streams microphone audio to a Hugging Face realtime
endpoint on AWS. To keep everything on this machine, run
[huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech) as the
realtime server and point its LLM slot at a local OpenAI-compatible server such as
[LM Studio](https://lmstudio.ai/).

```
mic -> conversation app --ws--> speech-to-speech :8765 --http--> LM Studio :1234
                                (Parakeet STT + Qwen3-TTS)       (your local model)
```

No app code is modified: this is the app's supported `HF_REALTIME_CONNECTION_MODE=local`
path. The same stack runs the hosted backend, so behaviour matches closely.

### Install

```bash
./setup-local-backend.sh            # or --locked for exact transitive versions
```

On Apple Silicon this pulls MLX, so STT and TTS run on the GPU. First start downloads
~2.5 GB of weights (Smart Turn VAD, Parakeet TDT, Qwen3-TTS) into `~/.cache/huggingface`.

### Run

Start the realtime server **before** the daemon and app:

```bash
cp local-backend.conf.example local-backend.conf   # set LLM_MODEL / LLM_BASE_URL
./run-local-backend.sh
```

The script checks the LLM server is reachable before starting, and passes the
flags explained under Notes below.

Wait for `OpenAI Realtime API starting on ws://127.0.0.1:8765/v1/realtime`, then
`cp .env.example .env` and start the daemon and app as usual.

Verify the app picked the local path — the log should show `connection mode: local` and no
requests to `pollen-robotics-reachy-mini-realtime-url.hf.space`.

### Corporate proxy (TLS interception)

Skip this section on an unrestricted network.

Model weights live in Hugging Face LFS, and those requests `302` to
`us.aws.cdn.hf.co`. Two separate things break there:

1. **The default egress proxy refuses that CDN** (`407`), even though it happily serves
   `huggingface.co` itself. Other proxies are listed in the PAC file at
   `http://wmtpac.wal-mart.com/proxies/anycast-universal.pac`; `proxy-intlho.wal-mart.com:8080`
   reaches both hosts. Check the PAC before concluding a host is blocked.
2. **That proxy re-signs TLS.** `curl` accepts it via the system keychain, but Python's
   `certifi` bundle does not, so `requests` raises `CERTIFICATE_VERIFY_FAILED`.
   `huggingface_hub` catches it and re-raises `LocalEntryNotFoundError`, whose message
   blames your internet connection — a red herring. To see the real error, retry the URL
   with a plain `requests.head()`.

```bash
./make-ca-bundle.sh                   # certifi roots + corporate roots
cp proxy.env.example proxy.env        # proxy + CA env vars in one place
./prefetch-models.sh                  # ~4.9 GB; resumable, re-run after a drop
```

`run-local-backend.sh` sources `proxy.env` when present. Also note `HF_HUB_DISABLE_XET=1`
in that file: `hf-xet` is a separate Rust HTTP stack that honours no proxy or CA variable.

### Notes

The installed CLI has **no `serve` subcommand**, despite what the upstream README shows;
that is only on `main`. Passing it fails with
`Some specified arguments are not used by the HfArgumentParser: ['serve']`.

The LLM server must implement the **Responses API** (`/v1/responses`), not just chat
completions. LM Studio does. `mlx_lm.server` does **not** — it exposes only
`/v1/chat/completions`, `/v1/completions`, and `/v1/models`, so it cannot be used here.
LM Studio runs MLX models natively, so prefer an MLX build of your model over swapping
servers.

`--responses_api_disable_thinking` matters for reasoning models: without it Qwen3 spends
most of its token budget on reasoning, adding dead air to every spoken turn.

Watch `Qwen3-TTS RTF` in the logs. Above 1.0 means synthesis is slower than realtime and
replies will lag; STT and TTS share an MLX lock and compete with the LLM for the GPU.

## Apps

Install official apps through the daemon API (or Reachy Mini Control). Run the daemon with
`--desktop-app-daemon` so apps install into a sibling `apps_venv/` instead of mutating this
environment:

```bash
mjpython -m reachy_mini.daemon.app.main --sim --desktop-app-daemon
./install-app.sh                      # defaults to the conversation app
curl -X POST http://127.0.0.1:8000/api/apps/start-app/reachy_mini_conversation_app
```

`install-app.sh` also applies the `mcp<2` pin described below; installing through
the raw API alone will leave the remote tools broken.

The conversation app's web UI is then at http://127.0.0.1:7860/. First start takes ~75 s
(fresh GStreamer registry scan in `apps_venv`).

### Known upstream bug: env leak into app subprocesses

`AppManager.start_app` scrubs `GST_*`/`XDG_*` from the app subprocess env but **not**
`PYTHONPATH` or `GST_PYTHONPATH_1_0`, both of which the daemon's `gstreamer_bundle.pth`
points at the *daemon's* site-packages. Because they take precedence over the target venv,
an app launched with `apps_venv`'s interpreter imports `reachy_mini` and `gi` from the
daemon's venv instead. Confirmed present in 1.10.0rc5.

This is invisible while the daemon and `apps_venv` hold the *same* SDK version — which is
why this project pins both to 1.10.0rc5. It bites as soon as they diverge, with either:

```
ModuleNotFoundError: No module named 'reachy_mini.io.jsonrpc'   # PYTHONPATH leak
ModuleNotFoundError: No module named 'gi'                        # GST_PYTHONPATH_1_0 leak
```

Two ways out. Run the app directly, bypassing the daemon launcher:

```bash
env -u PYTHONPATH -u GST_PYTHONPATH_1_0 ./apps_venv/bin/reachy-mini-conversation-app --ui
```

Or add both names to the scrub tuple in
`reachy_mini_env/lib/python3.12/site-packages/reachy_mini/apps/manager.py` (verified to
work, but a local edit that any `pip install -U reachy-mini` will silently revert).
