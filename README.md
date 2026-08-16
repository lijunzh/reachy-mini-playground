# Reachy Mini — simulator dev environment

Local development against the [Reachy Mini](https://huggingface.co/docs/reachy_mini) MuJoCo
simulator. No physical robot required: in sim the daemon presents itself as a Reachy Mini
Lite on `localhost`, so SDK scripts run unmodified on real hardware later.

Host this was set up on: macOS (Apple Silicon), Python 3.12, `reachy-mini` 1.10.0rc5,
`mujoco` 3.3.0.

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

## Apps

Install official apps through the daemon API (or Reachy Mini Control). Run the daemon with
`--desktop-app-daemon` so apps install into a sibling `apps_venv/` instead of mutating this
environment:

```bash
mjpython -m reachy_mini.daemon.app.main --sim --desktop-app-daemon
curl -X POST http://127.0.0.1:8000/api/apps/start-app/<app_name>
```

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
