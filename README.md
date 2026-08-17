# Ollama VRAM Watchdog

**Version: 1.2**

A lightweight bash script that monitors [Ollama](https://ollama.com/) for models that partially load into CPU memory and automatically corrects them by restarting Ollama and reloading the model fully into GPU VRAM.

## The Problem

Models may occasionally fail to load fully into VRAM, falling back partially or entirely to the CPU and causing degraded performance. This can happen due to LLM model-switching timing, insufficient available VRAM, or contention with other GPU-hungry containers (ComfyUI, Whisper, etc.) when running Ollama in Docker alongside them.

```
$ ollama ps
NAME          ID              SIZE     PROCESSOR          UNTIL
gemma3:27b    a418f5838eaf    22 GB    23%/77% CPU/GPU    3 days from now
```

This happens because other processes are occupying VRAM at the time the model loads. The result is significantly degraded inference performance since CPU memory is orders of magnitude slower than VRAM.

The fix is simple: free the VRAM and reload. But doing it manually every time is tedious. This script automates the entire process.

## How It Works

Note: This script prioritizes Ollama VRAM utilization over any other running application that may be using the GPU — *except* while a lock file signals that another workload has deliberately claimed the GPU (see [GPU Lock Coordination](#gpu-lock-coordination)). Feel free to adjust according to your preferences.

1. Every 15 seconds, checks for a GPU lock file. If a fresh lock is present, the entire cycle is skipped — another workload owns the card and any CPU spill is expected
2. Otherwise, checks `ollama ps` for any model with a non-zero CPU percentage
3. If found, captures a VRAM snapshot showing which processes and containers are holding VRAM
4. Stops other GPU containers (ComfyUI, Whisper, etc.) to free VRAM
5. Restarts the Ollama Docker container
6. Reloads the same model fully into GPU VRAM
7. Verifies the model is now fully on GPU
8. Restarts the other GPU containers
9. Gives up after 3 failed attempts per model (to avoid infinite loops if the model genuinely doesn't fit), then automatically retries once the give-up cooldown expires

## Requirements

- Ollama running as a Docker container
- `ollama` CLI accessible from the host (via port mapping)
- `docker` accessible without sudo (or run the script as root)
- `nvidia-smi` available on the host (optional, but required for VRAM snapshots — standard with the NVIDIA driver)
- `stat` and `date` (coreutils — present on any standard Linux install; used for lock-file age and cooldown timing)

## Quick Start

```bash
# Copy script, then Edit the configuration at the top of the script (See config options below)
vi ollama-vram-watchdog.sh

# Make it executable
chmod +x ollama-vram-watchdog.sh

# Run it
./ollama-vram-watchdog.sh
```

## Configuration

Edit the variables at the top of `ollama-vram-watchdog.sh`:

| Variable | Default | Description |
|---|---|---|
| `CONTAINER_NAME` | `ollama` | Name of your Ollama Docker container |
| `GPU_CONTAINERS` | `("comfyui" "whisper" "whisper-libretranslate")` | Other containers that may hold VRAM — these get stopped during reload |
| `CHECK_INTERVAL` | `15` | Seconds between checks |
| `MAX_RETRIES` | `3` | Max reload attempts per model before giving up |
| `KEEPALIVE` | `72h` | How long Ollama keeps the model loaded after reload |
| `LOG_FILE` | `~/ollama-vram-watchdog.log` | Log file path |
| `VERBOSE` | `1` | Log verbosity: `0`=quiet, `1`=normal, `2`=debug (logs every check cycle) |
| `VRAM_SNAPSHOTS` | `1` | `1`=capture `nvidia-smi` snapshots during incidents, `0`=disable |
| `LOCK_FILE` | `/tmp/jarvis_gpu.lock` | Lock file that, when present and fresh, pauses the watchdog entirely |
| `LOCK_STALE_SECS` | `300` | A lock older than this is treated as abandoned and ignored |
| `GIVEUP_COOLDOWN` | `3600` | Seconds before a given-up model is eligible for retry |

### GPU Containers

The `GPU_CONTAINERS` array should list any Docker containers on your system that use GPU memory. Common examples:

```bash
GPU_CONTAINERS=("comfyui" "whisper" "whisper-libretranslate" "stable-diffusion")
```

These containers are temporarily stopped to free VRAM during a model reload, then restarted afterward. If a container isn't running at the time, it's simply skipped.

### GPU Lock Coordination

The watchdog's remediation is blunt by design: it stops the other GPU containers to free VRAM. That's the right move when a model has spilled to CPU for no good reason — but it's exactly the wrong move when another workload has *deliberately* claimed the GPU and pushed Ollama aside on purpose.

The failure case this solves: an image generation job (a ComfyUI coloring-page render, driven by `gpuswap.py`) claims VRAM and squeezes the LLM. A voice command arrives mid-render, Gemma spills to CPU, the watchdog sees the spill and "frees VRAM" by running `docker stop comfyui` — killing the render mid-sampling. Both jobs lose.

To prevent this, the watchdog checks for `LOCK_FILE` at the top of every cycle. If a **fresh** lock exists, the entire cycle is skipped — no detection, no snapshot, no container stops. Once the lock clears, normal monitoring resumes and any genuine spill still gets fixed on the next pass.

The lock protocol is deliberately simple, so anything can participate:

```bash
# Claim the GPU
touch /tmp/jarvis_gpu.lock

# ... run your GPU workload ...

# Release it
rm -f /tmp/jarvis_gpu.lock
```

In this setup, the lock is written by `gpuswap.ensure_vram()` and cleared by `release_all()`.

**Staleness:** if a job crashes without cleaning up, a lock file would otherwise disable the watchdog forever. `LOCK_STALE_SECS` (default 300) caps this — a lock older than five minutes is logged and ignored.

> **Important:** staleness is measured from the file's **modification time**, not from when it was created. If your GPU job can run longer than `LOCK_STALE_SECS`, it must `touch` the lock periodically (say, every 60 seconds) to keep it fresh — otherwise the watchdog will consider it abandoned mid-job and resume remediating. Alternatively, raise `LOCK_STALE_SECS` above your longest expected run time, keeping in mind that this also lengthens how long a crashed job can suppress the watchdog.

Set `LOCK_FILE` to a path that never exists if you don't want this behavior at all.

### Give-Up Cooldown

After `MAX_RETRIES` failed reloads, the watchdog gives up on a model and stops it, on the assumption that it genuinely doesn't fit in available VRAM. Before v1.2 that state was permanent — the model stayed stopped until someone restarted the watchdog by hand. In practice, a temporary collision (an image render holding VRAM for a few minutes) could burn through all three retries and silently take the model offline for the rest of the day, with no obvious explanation for why voice responses had gone quiet.

`GIVEUP_COOLDOWN` (default 3600 seconds) puts an expiry on that state. Once the cooldown elapses and the model shows up spilled again, the retry counter resets and the watchdog takes another run at it. The give-up log line now states when the retry will happen:

```
[2026-08-17 14:06:01] GIVING UP: llama3:70b failed 3 times — likely not enough VRAM. Stopping model.
[2026-08-17 14:06:01]   (will retry automatically in 3600s)
```

Set it higher if you'd rather not see repeated attempts on a model that truly doesn't fit; the retry costs a container restart each time it fires.

### Verbose Logging and VRAM Snapshots

When `VRAM_SNAPSHOTS=1` (the default), the script calls `nvidia-smi` at three key moments during an incident:

1. **At detection** — immediately when a CPU offload is spotted, so you can see exactly what was holding VRAM at the moment of failure
2. **After freeing GPU containers** — confirms that stopping the other containers actually released the memory you expected
3. **After reload** — confirms the final state (successful or failed)

Each snapshot reports total/used/free VRAM and a per-process breakdown. The script walks each GPU process's cgroup to resolve it back to a Docker container name where possible, so your logs show `[container: comfyui]` rather than just a PID.

**Note on permissions:** The PID-to-container mapping reads `/proc/<pid>/cgroup`, which typically requires the script to run as root or as the container owner. If you see GPU processes logged without a `[container: ...]` tag, that's usually why — the snapshot itself (total/used/free) will still work fine. Running under the systemd unit below as root is the simplest way to get full container resolution.

Set `VRAM_SNAPSHOTS=0` to disable snapshots entirely, or set `VERBOSE=2` for additional debug output on every check cycle (useful when troubleshooting the watchdog itself). Note that lock-file skips are logged at debug level — if you're wondering why the watchdog appears idle during renders, run at `VERBOSE=2` to see the skip lines.

## Running as a Service (Recommended)

For a persistent setup that survives reboots:

```bash
sudo tee /etc/systemd/system/ollama-vram-watchdog.service > /dev/null <<'EOF'
[Unit]
Description=Ollama VRAM Watchdog
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=youruser
ExecStart=/home/youruser/ollama-vram-watchdog.sh #Replace with the actual path to the script
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama-vram-watchdog
sudo systemctl start ollama-vram-watchdog
```

Then manage it with:

```bash
systemctl status ollama-vram-watchdog   # check status
journalctl -u ollama-vram-watchdog -f   # follow logs
sudo systemctl stop ollama-vram-watchdog # stop
```

> **Note on the lock file:** the watchdog and whatever writes `LOCK_FILE` must agree on the path *and* both be able to see it. If either runs with systemd's `PrivateTmp=true`, each gets its own `/tmp` and the lock will never be visible across the boundary. Move `LOCK_FILE` to a shared path like `/run/jarvis_gpu.lock` if that applies to your setup.

### Alternative: tmux

```bash
tmux new -d -s watchdog '/home/youruser/ollama-vram-watchdog.sh' #Replace with the actual path to the script
```

> **Note:** Don't use cron for this. The script is a long-running loop, and cron would spawn overlapping instances that conflict with each other.

## Log Output

The watchdog logs to `~/ollama-vram-watchdog.log`. With `VRAM_SNAPSHOTS=1`, a successful fix looks like this:

```
[2026-08-17 14:00:15] DETECTED: gemma3:27b has 23% CPU offload
[2026-08-17 14:00:15] VRAM snapshot (at detection): 23847 MiB used / 24564 MiB total (717 MiB free), GPU 12% util
[2026-08-17 14:00:15]   PID 3421 (python) [container: comfyui] → 8234 MiB
[2026-08-17 14:00:15]   PID 5102 (python3) [container: whisper] → 3128 MiB
[2026-08-17 14:00:15]   PID 9876 (ollama) [container: ollama] → 12485 MiB
[2026-08-17 14:00:15] Attempting reload of gemma3:27b (attempt 1/3)...
[2026-08-17 14:00:15] Stopping GPU container: comfyui
[2026-08-17 14:00:22] VRAM snapshot (after freeing GPU containers): 12485 MiB used / 24564 MiB total (12079 MiB free), GPU 0% util
[2026-08-17 14:00:22]   PID 9876 (ollama) [container: ollama] → 12485 MiB
[2026-08-17 14:00:22] Restarting container: ollama
[2026-08-17 14:00:25] Waiting for ollama to come back up...
[2026-08-17 14:00:30] Running: ollama run gemma3:27b
[2026-08-17 14:00:47] FIXED: gemma3:27b is now fully on GPU
[2026-08-17 14:00:47] VRAM snapshot (after successful reload): 22103 MiB used / 24564 MiB total (2461 MiB free), GPU 8% util
[2026-08-17 14:00:47]   PID 12044 (ollama) [container: ollama] → 22103 MiB
[2026-08-17 14:00:47] Restarting GPU container: comfyui
```

Standing down while another workload holds the GPU (`VERBOSE=2`, since these are debug-level):

```
[2026-08-17 15:12:03] DEBUG: jarvisprinting holds the GPU -- skipping this cycle
[2026-08-17 15:12:18] DEBUG: jarvisprinting holds the GPU -- skipping this cycle
[2026-08-17 15:12:33] DEBUG: jarvisprinting holds the GPU -- skipping this cycle
[2026-08-17 15:12:48] DEBUG: Running ollama ps check
```

An abandoned lock being aged out (logged at normal verbosity):

```
[2026-08-17 15:20:11] Lock file is stale (412s old) -- ignoring and proceeding
[2026-08-17 15:20:11] DETECTED: gemma3:27b has 31% CPU offload
```

Model too large for available VRAM, and the automatic retry an hour later:

```
[2026-08-17 14:05:01] STILL BAD: llama3:70b still showing 45% CPU
[2026-08-17 14:05:01] VRAM snapshot (after failed reload): 24289 MiB used / 24564 MiB total (275 MiB free), GPU 3% util
[2026-08-17 14:05:01]   PID 15432 (ollama) [container: ollama] → 24289 MiB
[2026-08-17 14:05:30] STILL BAD: llama3:70b still showing 45% CPU
[2026-08-17 14:06:01] GIVING UP: llama3:70b failed 3 times — likely not enough VRAM. Stopping model.
[2026-08-17 14:06:01]   (will retry automatically in 3600s)
[2026-08-17 15:06:16] COOLDOWN EXPIRED: retrying llama3:70b after 3600s
[2026-08-17 15:06:16] DETECTED: llama3:70b has 45% CPU offload
[2026-08-17 15:06:16] Attempting reload of llama3:70b (attempt 1/3)...
```

## How It's Safe to Run Continuously

- When no models are split, the script does almost nothing — just runs `ollama ps` (a tiny HTTP call) every 15 seconds
- It only takes action when it detects an actual problem
- VRAM snapshots only fire during incidents, not on every check — so the idle overhead stays negligible
- The 3-attempt cap prevents runaway restart loops, and the give-up cooldown prevents a model from being sidelined permanently
- The lock file lets deliberate GPU workloads suppress remediation entirely, so the watchdog never stops a container out from under an in-flight job
- A stale lock can't disable the watchdog indefinitely — it ages out after `LOCK_STALE_SECS`
- Other GPU containers are always restarted after a reload attempt, whether it succeeds or fails

## Changelog

### v1.2 (current)

- **Added GPU lock-file coordination.** The watchdog now skips its entire check cycle while a fresh `LOCK_FILE` (default `/tmp/jarvis_gpu.lock`) is present, written by `gpuswap.ensure_vram()` and cleared by `release_all()`. Without this, an ordinary voice command during a coloring-page render would spill the LLM to CPU, the watchdog would "free VRAM" with `docker stop comfyui`, and the render would die mid-sampling.
- **Added `LOCK_STALE_SECS`** (default `300`) so a crashed job that never cleans up its lock can't suppress the watchdog forever. Stale locks are logged and ignored. Note that staleness is based on mtime, so long-running jobs should `touch` the lock periodically.
- **Added `GIVEUP_COOLDOWN`** (default `3600`). Give-up state now expires instead of lasting until the watchdog is restarted by hand. Previously, three failed retries left a model stopped indefinitely with no indication of why voice had gone silent — a transient VRAM collision could take a model offline for the rest of the day.
- **Give-up log line now states when the automatic retry will occur**, and a `COOLDOWN EXPIRED` line is logged when the model is picked back up.
- **Startup banner reports the lock file path, staleness threshold, and give-up cooldown**, alongside the existing version and verbosity settings.

### v1.1

- **Added VRAM snapshot logging.** When an incident is detected, the script now captures `nvidia-smi` output at three key moments: at detection, after freeing GPU containers, and after the reload completes. Each snapshot reports total/used/free VRAM plus a per-process breakdown.
- **Added PID-to-container resolution.** GPU processes are mapped back to their Docker container names by walking `/proc/<pid>/cgroup` (supports both cgroups v1 and v2), so logs now show `[container: comfyui]` rather than bare PIDs.
- **Added `VERBOSE` config knob** (`0`=quiet, `1`=normal, `2`=debug). Debug mode logs every check cycle and additional state transitions — useful when troubleshooting the watchdog itself.
- **Added `VRAM_SNAPSHOTS` config knob** to disable snapshot logging independently of verbosity, for systems without `nvidia-smi` or where the extra output isn't wanted.
- **Startup banner now reports the active version and verbosity settings**, and warns once at startup if `VRAM_SNAPSHOTS=1` but `nvidia-smi` isn't available.
- **Container start/stop now uses `log_debug`** when a target container isn't present, so quiet mode stays quiet.

### v1.0

- Initial release. Detects CPU offload in `ollama ps`, stops configured GPU containers, restarts the Ollama container, reloads the model, and verifies the result. Three-strike retry cap per model.

## License

MIT