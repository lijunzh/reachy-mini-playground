# Reachy Mini — simulator dev environment

Local development against the [Reachy Mini](https://huggingface.co/docs/reachy_mini) MuJoCo
simulator. No physical robot required: in sim the daemon presents itself as a Reachy Mini
Lite on `localhost`, so SDK scripts run unmodified on real hardware later.

**macOS (Apple Silicon) only.** The scripts refuse to run elsewhere: `mjpython` needs a
macOS-specific dylib fix, and the local conversation backend pulls MLX, which has no Intel
build. Python 3.12, `reachy-mini` 1.10.0, `mujoco` 3.3.0.

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
| Conversation app | constrained inside the script (`mcp<2`) | `./install-app.sh` | 1.3 GB |
| Realtime backend | `requirements-s2s.txt` / `requirements-s2s.lock.txt` | `./setup-local-backend.sh` | 1.7 GB + 2.5 GB weights |
| LLM server (opt-in) | Homebrew formula `jundot/omlx/omlx` | `./setup-llm-server.sh` | 3.6 GB |

Full sequence on a new machine with internet access:

```bash
./setup.sh                                         # 1. simulator env
./setup-local-backend.sh                           # 2. speech-to-speech realtime server
./setup-llm-server.sh                              # 3. oMLX (or skip and use LM Studio)
cp .env.example .env                               # 4. point the app at the local backend
cp local-backend.conf.example local-backend.conf   # 5. LLM settings (defaults to oMLX)

./start.sh                                         # 6. brings up the stack, installs
                                                   #    the app on first run
```

`./start.sh` installs the conversation app on first run if it is missing, so there is no
separate install step. It handles start order and health-waits for you.

Machine-specific files (`.env`, `local-backend.conf`) are gitignored; copy them from the
`.example` versions. Skip steps 2, 3 and 5 to use the hosted Hugging Face backend instead;
skip only step 3 to use LM Studio as the LLM server.

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

One command brings the whole stack up in the right order, waiting on each
component's health rather than sleeping:

`./stop.sh` also cleans up what the launcher opened: the browser tab pointing at `:7860`,
and the simulator's Terminal window. Both are matched precisely — the tab by URL, the
window by the custom title `start.sh` sets on it — so other tabs and other Terminal
windows, including the one running `stop.sh`, are left alone.

```bash
./start.sh              # simulator with the MuJoCo viewer
./start.sh --headless   # no viewer (saves the ~200% CPU camera feed)
./start.sh --cloud      # hosted Hugging Face backend; skips oMLX and speech-to-speech
./stop.sh               # stop app, daemon, realtime server
./stop.sh --all         # also stop oMLX
```

Cold start measured at **25 s** with models already cached. It is idempotent —
anything already running is left alone — and logs land in `logs/`.

**Click to start.** `Reachy Mini.command` and `Stop Reachy Mini.command` are
double-clickable in Finder (macOS runs `.command` files in Terminal). Drag them to the
Dock if you want them there. The start one brings up the viewer, opens the conversation UI
when it is ready, and installs the app if this is the first run; closing its window does
**not** stop the servers.

On first run it will take several minutes — it installs the app (~1.3 GB) — and the
progress is in `logs/install-app.log`.

Three details the script handles that are easy to get wrong by hand:

- The realtime server exits immediately if no LLM is listening yet.
- The app reports `state: running` before it has connected to that realtime backend, so
  the launcher polls for the socket rather than trusting the status.
- **The viewer needs a foreground session.** `mjpython` must own the main thread to hold
  the MuJoCo window, so a backgrounded daemon serves fine but never shows a robot — and
  dies when the launching window closes. With a viewer, `start.sh` opens a dedicated
  Terminal window for the daemon; `--headless` backgrounds it as normal. Leave that window
  open: closing it stops the robot.

<details>
<summary>Starting the components by hand</summary>


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

</details>

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

**Skip this whole section on an unrestricted network.** Nothing here runs unless you
create `proxy.env`, which is gitignored and never present on a fresh clone. Without it,
`run-local-backend.sh` and `prefetch-models.sh` use settings tuned for a normal
connection: the full emotions library including its sound effects, and the usual eight
parallel download workers.

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

Creating `proxy.env` is what switches both scripts into proxy mode, so keep it out of
version control (it is already in `.gitignore`) and delete it if the machine moves off
the corporate network.

`run-local-backend.sh` sources `proxy.env` when present. Also note `HF_HUB_DISABLE_XET=1`
in that file: `hf-xet` is a separate Rust HTTP stack that honours no proxy or CA variable.

**Start the daemon with `proxy.env` sourced too.** App subprocesses inherit the daemon's
environment, and without it `play_emotion` and `dance` fail with
`ConnectError: [Errno 8] nodename nor servname provided` when they reach for their
libraries — a DNS failure, not a missing asset.

### What stays broken behind the proxy

The LLM is on `127.0.0.1` and needs no proxy at all, so conversation itself is unaffected.
Two things that genuinely reach the internet do not survive:

| Feature | Status |
| --- | --- |
| `get_weather`, `search_web`, `get_time` | Blocked. Hosted as MCP servers on `*.hf.space`, which the web gateway answers with `403 URLBlocked`. |
| Emotion sound effects (84 `.ogg`) | Blocked with `403` on the CDN. `prefetch-models.sh` skips them, so emotions play as movement without audio. |

When a tool fails, the model narrates it in the first person — "my internet seems down" —
which reads like a diagnosis but is just the tool error paraphrased. Check the logs for
`URLBlocked` before believing it.

### Notes

The installed CLI has **no `serve` subcommand**, despite what the upstream README shows;
that is only on `main`. Passing it fails with
`Some specified arguments are not used by the HfArgumentParser: ['serve']`.

### Which LLM server

**Default: [oMLX](https://github.com/jundot/omlx)**, opt-in during setup:

```bash
./setup-llm-server.sh     # installs via Homebrew and seeds ~/.omlx/settings.json
```

Then run it either way:

```bash
./run-llm-server.sh           # foreground — easiest to watch and Ctrl-C
brew services start omlx      # background, auto-restarts on crash
brew services info omlx       # status;  omlx start | stop | restart
```

It is deliberately not part of `setup.sh`: the simulator never needs it, and it pulls
~3.6 GB (omlx, plus `rust` and `llvm@22` as **build-only** deps) from a third-party tap.
The runtime dependency tree is just `python@3.11`. LM Studio is a workable alternative —
see below.

**Configuration lives in `~/.omlx/settings.json`, not only in CLI flags.** The flags
write to that file, and oMLX reads it at startup. That is what makes `brew services`
usable: its service definition runs a bare `omlx serve`, which still gets the prefix
cache because the settings persist. `setup-llm-server.sh` seeds the file so this is true
before the first start — without it, the service would silently run with the cache off.

```
[cache]  ssd_cache_dir, ssd_cache_max_size, hot_cache_max_size
[server] host, port
```

Verified: a bare `omlx serve` with no flags reports `cached=6144` and 0.58 s/turn,
identical to the flag-driven run.

> **Homebrew is the only supported install path.** oMLX also ships pip wheels, but
> `~/.omlx/settings.json` is global and last-writer-wins: a second install silently
> overwrites the first one's port and cache directory. `setup-llm-server.sh` refuses to
> run if a non-Homebrew `omlx` shadows the Homebrew one. Homebrew is also what provides
> `brew services` (auto-restart, managed logs) and `brew upgrade`, which a wheel install
> cannot.

**Monitoring.** The CLI server serves a web console at http://127.0.0.1:8123/admin —
logs, metrics, throughput, cache and batch state, and one-click benchmarking. Set an API
key on first visit, then use the same value as `LLM_API_KEY` in `local-backend.conf`.
`GET /health` gives the same status as JSON, and `/docs` is the OpenAPI page. **The
macOS `.dmg` is not needed for any of this** — it adds a menu-bar wrapper around the same
server, is macOS-version-locked, and is manual to update.

Under `brew services`, logs go to `$(brew --prefix)/var/log/omlx.log`.

**Context size is what decides this.** The conversation app sends a large stable prefix
(instructions, tool schemas, growing history). From a real session's own accounting:

```
this response: input_tokens=8879 / 8937 / 8979 / 9341
```

**~9,000 tokens per turn**, so a prefix cache dominates. Measured on identical prompts at
a 6,656-token context:

| Setup | warm/turn | caches? |
| --- | --- | --- |
| **oMLX** (MLX + prefix cache) | **0.58 s** | yes, 6144 tokens |
| LM Studio, **GGUF** model (llama.cpp) | ~1.07 s | yes |
| LM Studio, **MLX** model | 5.13 s | **no** |

Two things follow. oMLX is fastest, by roughly 2x over a well-configured LM Studio. And
if you stay on LM Studio, **use a GGUF model, not MLX** — its MLX engine re-prefills the
whole prompt every request. (The GGUF row used a larger model, so treat the 0.58 vs 1.07
gap as indicative rather than exact.)

Three traps, all of which cost measurable time to find:

- oMLX caches in **2048-token blocks**. Below ~2048 tokens nothing is cacheable and oMLX
  looks *worse* than LM Studio (0.46 s vs 1.03 s at ~700-token prompts). Benchmark at
  your real context size or the result is meaningless.
- oMLX's cache is **off by default** — without `--paged-ssd-cache-dir` it reports
  `cached=0`. `run-llm-server.sh` passes it. Its README's `--hot-cache-max-size 20%` is
  rejected; the flag wants an absolute size.
- LM Studio's **loaded context length** defaults well below what the app sends. At ~9k
  tokens it refuses outright with `HTTP 400: The number of tokens to keep from the
  initial prompt is greater than the context length`. Ours was 8192 against a model
  maximum of 262144.

**Backend selection.** `speech-to-speech` defaults to the Responses API (`/v1/responses`),
which LM Studio implements and oMLX does not. `local-backend.conf` selects it:

```bash
LLM_BACKEND="chat-completions"            # omlx, mlx_lm.server
LLM_BASE_URL="http://127.0.0.1:8123/v1"
```

`--llm_backend` accepts `transformers`, `mlx-lm`, `responses-api` and `chat-completions`;
the chat-completions backend reuses the same `--responses_api_base_url` /
`--responses_api_api_key` flags.

**Model choice still outweighs the server for reasoning models.** A reasoning model spends
most of its budget thinking (measured: 86% of tokens, 13.2 s/turn on `qwen3.8-27b`). Use
an instruct build.

Re-measure any of this with `bench-llm.py`, at your real context size rather than a toy
prompt:

```bash
./reachy_mini_env/bin/python bench-llm.py "omlx" http://127.0.0.1:8123/v1 <model-id> --chat
```

**Use a non-reasoning (instruct) model.** This matters more than any flag.
`--responses_api_disable_thinking` sends `chat_template_kwargs.enable_thinking=false`,
which vLLM honours but **LM Studio's llama.cpp backend ignores**. Measured against
LM Studio with `qwen/qwen3.8-27b`:

| Request | reasoning tokens |
| --- | --- |
| baseline | 29 |
| `chat_template_kwargs.enable_thinking=false` (what the flag sends) | 15 |
| `reasoning_effort: "none"` | 11 |

Never zero. A realistic conversational turn came back with **180 of 211 tokens spent on
reasoning, taking 15.2 s** before the first spoken word. The flag is left in
`run-local-backend.sh` because it costs nothing and works against vLLM-style servers, but
do not rely on it with LM Studio.

Watch `Qwen3-TTS RTF` in the logs. It is audio duration divided by generation time, so
**higher is better** and below 1.0 means synthesis is slower than realtime. Measured here:
3.88-3.93, i.e. about 4x faster than realtime. STT and TTS share an MLX lock and compete
with the LLM for the GPU, so this drops under contention.

### Troubleshooting: Reachy never answers

Symptoms in the speech-to-speech log:

```
speech during pending response: cancelled, queue flushed
LLM generation cancelled (interruption)
Skipping stale LLM request for turn=turn_15 rev=10
```

with the same sentence re-transcribed several times on a growing buffer
(`audio=2.984s` then `4.764s`, `rev=0,1,2...`).

The LLM is not looping and LM Studio is not stuck. The *turn* never closes: any sound
during the 800 ms speculative reopen grace reopens it, Parakeet re-transcribes the whole
buffer, and the in-flight LLM request is abandoned. A slow model never wins that race, so
the reply is generated and then thrown away.

Fixes, most effective first:

1. Switch to a non-reasoning (instruct) model — removes ~85% of generated tokens.
2. Use a server with a prefix cache. At the app's real ~9k-token context this is worth
   ~9x on its own; see "Which LLM server" above.
3. Raise the VAD threshold (`--thresh`) so ambient noise stops reopening turns.
4. Verify the model is not the bottleneck by calling it directly at your real context
   size; if a single request takes >5 s, no amount of VAD tuning will help.

### Measured resource profile

Real conversation, 208 samples at 1 Hz, with oMLX serving `Qwen3-Coder-Next-MLX-4bit`:

| Component | CPU median | CPU p95 | RSS |
| --- | --- | --- | --- |
| daemon (simulator) | **198.7%** | 206.0% | 1.92 GB |
| speech-to-speech | 3.6% | 110.1% | 5.51 GB |
| oMLX | 0.3% | 71.9% | 42.6 GB |
| conversation app | 8.7% | 11.3% | 0.19 GB |

Per stage: STT 0.029-0.047 s, TTS time-to-first-audio 0.10 s, RTF 3.88-3.93, context
7,078-7,561 tokens per turn, zero turn cancellations.

Three things worth knowing:

- **The simulator is the biggest CPU consumer**, not the AI stack — ~200% constant whether
  or not anyone is talking. That is the uncompressed camera feed described under Notes.
  `--headless` removes it.
- **oMLX and speech-to-speech are near-idle between turns** (0.3% and 3.6% median) and
  spike to roughly one core each while generating. Both preallocate memory: neither RSS
  moved at all across the session.
- **oMLX's 42.6 GB is preallocation**, driven by `max_model_len` (262,144 tokens for this
  model) plus the hot cache, not by working set. The model itself is ~17 GB at 4-bit. Cap
  the context in `~/.omlx/settings.json` if you need the memory back.

### Custom tools (no fork needed)

The app loads external tool modules at runtime, so capabilities can be added from this
repo without forking it:

```bash
REACHY_MINI_EXTERNAL_TOOLS_DIRECTORY=./tools    # in .env
AUTOLOAD_EXTERNAL_TOOLS=true
```

Any `*.py` in that directory whose name is a valid identifier is imported; the module
name is the tool name. A tool is one class -- see `tools/fetch_url.py`, or upstream's
`external_content/external_tools/starter_custom_tool.py` template:

```python
class MyTool(Tool):
    name = "my_tool"
    description = "..."            # the model reads this to decide when to call it
    parameters_schema = {...}      # JSON schema
    async def __call__(self, deps: ToolDependencies, **kwargs) -> dict[str, Any]: ...
```

`deps` carries the robot handle, so motion-type actions are possible too. Prefer this
over forking: the realtime plumbing, audio pipeline, VAD and UI are all things you would
inherit and have to rebase forever, and none of them is what a new capability needs.

#### `tools/fetch_url.py`

Fetches a page and returns readable text, closing the gap below. It uses only `httpx`
(already an app dependency) and the standard library, so it adds nothing that could
collide with the app's own pins -- the failure mode that `mcp 2.x` caused.

It refuses loopback and private addresses, resolving DNS first and re-checking after
redirects. That matters here: the tool runs on the same host as the Reachy daemon on
`:8000`, which can drive the robot, plus the LLM server and anything else local. A model
can be steered into requesting a URL by a prompt-injecting page, so local services are
not reachable through it by design.

Verified end to end: the module is discovered, appears in the tool list offered to the
model, and the model calls it with sensible arguments when asked to read a page.

### The assistant cannot read web pages

Only `search_web` exists, and it returns `{title, snippet, url}` — search results, not page
content. There is no fetch, browse, or open-url tool, so the model correctly answers "I
can't open web pages directly, but I can copy the link for you". This is a missing
capability in the app's tool inventory, not an LLM or server problem; tool calls
themselves succeed. Adding an MCP Tool Space that fetches page text would close it.

## Apps

Install official apps through the daemon API (or Reachy Mini Control). Run the daemon with
`--desktop-app-daemon` so apps install into a sibling `apps_venv/` instead of mutating this
environment:

```bash
mjpython -m reachy_mini.daemon.app.main --sim --desktop-app-daemon
./install-app.sh                      # defaults to the conversation app
curl -X POST http://127.0.0.1:8000/api/apps/start-app/reachy_mini_conversation_app
```

`install-app.sh` also checks the `mcp` pin described below. Since app version 1.0.1
upstream declares `mcp<2,>=1.27.1` itself, so a fresh install no longer pulls the broken
2.x; the check stays as a guard for older installs and reports "already <2" when there is
nothing to do.

The conversation app's web UI is then at http://127.0.0.1:7860/. First start takes ~75 s
(fresh GStreamer registry scan in `apps_venv`).

### After an SDK bump, realign apps_venv explicitly

`install-app.sh` will **not** upgrade a dependency that is already satisfied. After
bumping `reachy-mini` in the daemon venv, reinstalling the app leaves `apps_venv` on the
old SDK, because the old version still satisfies the app's lower bound. A fresh clone
resolves correctly only because its `apps_venv` starts empty.

The symptom is the app logging, on startup:

```
RuntimeWarning: Reachy Mini SDK and daemon versions do not match:
SDK=<old>, daemon=<new>. Running different versions can create issues.
```

Fix it in the app's own venv, matching whatever `requirements.txt` pins:

```bash
./apps_venv/bin/pip install --upgrade "reachy-mini==1.10.0" "mcp<2"
```

Check alignment with:

```bash
./reachy_mini_env/bin/python -c "import importlib.metadata as m; print(m.version('reachy-mini'))"
./apps_venv/bin/python       -c "import importlib.metadata as m; print(m.version('reachy-mini'))"
```

### `state: running` does not mean the backend connected

`/api/apps/current-app-status` reports whether the app *process* is alive, not whether it
reached its realtime backend. With `speech-to-speech` down, the app still reports
`"state":"running"` while logging:

```
Backend failed to start: [Errno 61] Connect call failed
```

Confirm the connection rather than trusting the status, from the server side:

```bash
lsof -nP -iTCP:8765 -sTCP:ESTABLISHED     # expect 127.0.0.1:8765 -> 127.0.0.1:<port>
```

The speech-to-speech log should show `Client connected` and `Session configuration`.

### Known upstream bug: env leak into app subprocesses

`AppManager.start_app` scrubs `GST_*`/`XDG_*` from the app subprocess env but **not**
`PYTHONPATH` or `GST_PYTHONPATH_1_0`, both of which the daemon's `gstreamer_bundle.pth`
points at the *daemon's* site-packages. Because they take precedence over the target venv,
an app launched with `apps_venv`'s interpreter imports `reachy_mini` and `gi` from the
daemon's venv instead. Confirmed present in 1.10.0.

This is invisible while the daemon and `apps_venv` hold the *same* SDK version — which is
why this project pins both to 1.10.0. It bites as soon as they diverge, with either:

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
