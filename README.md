# Ollama VRAM Watchdog

A lightweight bash script that monitors [Ollama](https://ollama.com/) for models that partially load into CPU memory and automatically corrects them by restarting Ollama and reloading the model fully into GPU VRAM.

## The Problem

Models may occasionally fail to load fully into VRAM, falling back partially or entirely to CPU and causing degraded performance. This can happen due to LLM model-switching timing, insufficient available VRAM, or contention with other GPU-hungry containers (ComfyUI, Whisper, etc.) when running Ollama in Docker alongside them.

```
$ ollama ps
NAME          ID              SIZE     PROCESSOR          UNTIL
gemma3:27b    a418f5838eaf    22 GB    23%/77% CPU/GPU    3 days from now
```

This happens because other processes are occupying VRAM when the model loads. The result is significantly degraded inference performance since CPU memory is orders of magnitude slower than VRAM.

The fix is simple — free the VRAM and reload — but doing it manually every time is tedious. This script automates the entire process.

## How It Works

1. Every 15 seconds, checks `ollama ps` for any model with a non-zero CPU percentage
2. If found, stops other GPU containers (ComfyUI, Whisper, etc.) to free VRAM
3. Restarts the Ollama Docker container
4. Reloads the same model
5. Verifies the model is now fully on GPU
6. Restarts the other GPU containers
7. Gives up after 3 failed attempts per model (to avoid infinite loops if the model genuinely doesn't fit)

## Requirements

- Ollama running as a Docker container
- `ollama` CLI accessible from the host (via port mapping)
- `docker` accessible without sudo (or run the script as root)
- Bash 4+ (for associative arrays)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/ollama-vram-watchdog.git
cd ollama-vram-watchdog

# Edit the configuration at the top of the script
nano ollama-vram-watchdog.sh

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

### GPU Containers

The `GPU_CONTAINERS` array should list any Docker containers on your system that use GPU memory. Common examples:

```bash
GPU_CONTAINERS=("comfyui" "whisper" "whisper-libretranslate" "stable-diffusion")
```

These containers are temporarily stopped to free VRAM during a model reload, then restarted afterward. If a container isn't running at the time, it's simply skipped.

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
User=wesley
ExecStart=/home/wesley/ollama-vram-watchdog.sh
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

### Alternative: tmux

```bash
tmux new -d -s watchdog '/home/wesley/ollama-vram-watchdog.sh'
```

> **Note:** Don't use cron for this. The script is a long-running loop, and cron would spawn overlapping instances that conflict with each other.

## Log Output

The watchdog logs to `~/ollama-vram-watchdog.log`. Successful fix:

```
[2026-03-21 14:00:15] Attempting reload of gemma3:27b (attempt 1/3)...
[2026-03-21 14:00:15] Stopping GPU container: comfyui
[2026-03-21 14:00:22] Restarting container: ollama
[2026-03-21 14:00:25] Waiting for ollama to come back up...
[2026-03-21 14:00:30] Running: ollama run gemma3:27b
[2026-03-21 14:00:47] FIXED: gemma3:27b is now fully on GPU
[2026-03-21 14:00:47] Restarting GPU container: comfyui
```

Model too large for available VRAM:

```
[2026-03-21 14:05:01] STILL BAD: llama3:70b still showing 45% CPU
[2026-03-21 14:05:30] STILL BAD: llama3:70b still showing 45% CPU
[2026-03-21 14:06:01] GIVING UP: llama3:70b failed 3 times — likely not enough VRAM. Stopping model.
```

## How It's Safe to Run Continuously

- When no models are split, the script does almost nothing — just runs `ollama ps` (a tiny HTTP call) every 15 seconds
- It only takes action when it detects an actual problem
- The 3-attempt cap prevents runaway restart loops
- Other GPU containers are always restarted after a reload attempt, whether it succeeds or fails

## License

MIT
