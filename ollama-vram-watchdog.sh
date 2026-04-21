#!/bin/bash

# ollama-vram-watchdog.sh
# Version: 1.1
#
# Monitors 'ollama ps' for models partially or fully loaded on CPU and automatically
# restarts ollama (Docker) to force a clean GPU reload.
#
# Designed for systems where ollama runs in Docker alongside other GPU containers
# (e.g., ComfyUI, Whisper) that may occupy VRAM and cause models to spill into CPU.
#
# Supported 'ollama ps' PROCESSOR column formats:
#   "100% CPU"          → fully offloaded to CPU
#   "48%/52% CPU/GPU"   → partially on CPU
#   "100% GPU"          → fully on GPU (no action needed)
#
# Usage:
#   chmod +x ollama-vram-watchdog.sh
#   ./ollama-vram-watchdog.sh
#
# See README.md for full setup instructions.

# ─── Configuration ───────────────────────────────────────────────────────────

CONTAINER_NAME="ollama"                                      # Name of your ollama Docker container
GPU_CONTAINERS=("comfyui" "whisper" "whisper-libretranslate") # Containers that may hold VRAM
CHECK_INTERVAL=15                                            # Seconds between checks
MAX_RETRIES=3                                                # Max reload attempts per model before giving up
KEEPALIVE="72h"                                              # How long ollama keeps the model loaded
LOG_FILE="$HOME/ollama-vram-watchdog.log"                    # Log file location

# Verbose logging (new in v1.1)
VERBOSE=1                                                    # 0=quiet, 1=normal, 2=debug (logs every check cycle)
VRAM_SNAPSHOTS=1                                             # 1=capture nvidia-smi snapshots during incidents, 0=disable

# ─── Functions ───────────────────────────────────────────────────────────────

declare -A retry_counts

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_debug() {
    [[ "$VERBOSE" -ge 2 ]] && log "DEBUG: $*"
}

# Map a PID to its Docker container name, if any.
# Reads /proc/<pid>/cgroup and resolves the container ID against `docker ps`.
# Returns empty string if not a container process, or if cgroup is unreadable.
pid_to_container() {
    local pid="$1"
    [[ -z "$pid" || ! -r "/proc/$pid/cgroup" ]] && return

    # Handle both cgroups v1 (/docker/<id>) and v2 (docker-<id>.scope) formats
    local cid
    cid=$(grep -oE 'docker[-/][0-9a-f]{12,}' "/proc/$pid/cgroup" 2>/dev/null \
          | head -1 | grep -oE '[0-9a-f]{12,}' | head -c 12)
    if [[ -n "$cid" ]]; then
        docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null \
            | awk -v id="$cid" '$1 ~ "^"id {print $2; exit}'
    fi
}

# Log a detailed snapshot of current VRAM usage and per-process breakdown.
# $1 = context string (e.g. "at detection", "after freeing", "after reload")
log_vram_snapshot() {
    local context="$1"

    [[ "$VRAM_SNAPSHOTS" -ne 1 ]] && return

    if ! command -v nvidia-smi &>/dev/null; then
        log_debug "nvidia-smi not available, skipping VRAM snapshot"
        return
    fi

    # Overall VRAM usage
    local mem_info
    mem_info=$(nvidia-smi --query-gpu=memory.total,memory.used,memory.free,utilization.gpu \
                          --format=csv,noheader,nounits 2>/dev/null)
    if [[ -n "$mem_info" ]]; then
        local total used free gpu_util
        IFS=',' read -r total used free gpu_util <<< "$mem_info"
        total=$(echo "$total" | xargs)
        used=$(echo "$used" | xargs)
        free=$(echo "$free" | xargs)
        gpu_util=$(echo "$gpu_util" | xargs)
        log "VRAM snapshot ($context): ${used} MiB used / ${total} MiB total (${free} MiB free), GPU ${gpu_util}% util"
    else
        log "VRAM snapshot ($context): nvidia-smi query failed"
        return
    fi

    # Per-process breakdown with container resolution
    local procs
    procs=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory \
                       --format=csv,noheader,nounits 2>/dev/null)
    if [[ -z "$procs" ]]; then
        log "  (no GPU processes reported)"
        return
    fi

    while IFS=',' read -r pid pname pmem; do
        pid=$(echo "$pid" | xargs)
        pname=$(echo "$pname" | xargs)
        pmem=$(echo "$pmem" | xargs)
        [[ -z "$pid" ]] && continue

        local container
        container=$(pid_to_container "$pid")
        if [[ -n "$container" ]]; then
            log "  PID $pid ($pname) [container: $container] → ${pmem} MiB"
        else
            log "  PID $pid ($pname) [host process] → ${pmem} MiB"
        fi
    done <<< "$procs"
}

# Extract CPU percentage from an 'ollama ps' line.
# Returns the CPU percentage (0-100), or nothing if no CPU usage detected.
# Handles:
#   "100% CPU"         → 100
#   "48%/52% CPU/GPU"  → 48
#   "100% GPU"         → (nothing, fully on GPU)
get_cpu_pct() {
    local line="$1"

    # Check for split format first: "X%/Y% CPU/GPU"
    local split_match
    split_match=$(echo "$line" | grep -oE '[0-9]+%/[0-9]+% CPU/GPU')
    if [[ -n "$split_match" ]]; then
        echo "$split_match" | grep -oE '^[0-9]+'
        return
    fi

    # Check for full CPU offload: "100% CPU" or "N% CPU"
    local cpu_match
    cpu_match=$(echo "$line" | grep -oE '[0-9]+% CPU')
    if [[ -n "$cpu_match" ]]; then
        echo "$cpu_match" | grep -oE '^[0-9]+'
        return
    fi

    # "100% GPU" or anything else → no CPU usage
}

stop_gpu_containers() {
    for c in "${GPU_CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
            log "Stopping GPU container: $c"
            docker stop "$c"
        else
            log_debug "GPU container $c not running, skipping stop"
        fi
    done
    sleep 5  # give VRAM time to fully release
}

start_gpu_containers() {
    for c in "${GPU_CONTAINERS[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
            log "Restarting GPU container: $c"
            docker start "$c"
        else
            log_debug "GPU container $c does not exist, skipping start"
        fi
    done
}

reload_model() {
    local model="$1"
    local attempt="$2"

    log "Attempting reload of $model (attempt $attempt/$MAX_RETRIES)..."

    # Stop the model first
    ollama stop "$model" 2>/dev/null
    sleep 2

    # Free up VRAM by stopping other GPU containers
    stop_gpu_containers
    log_vram_snapshot "after freeing GPU containers"

    # Restart ollama container
    log "Restarting container: $CONTAINER_NAME"
    docker restart "$CONTAINER_NAME"

    # Wait for ollama to be responsive (up to 60s)
    log "Waiting for ollama to come back up..."
    for i in {1..60}; do
        ollama list &>/dev/null && break
        sleep 1
    done

    if ! ollama list &>/dev/null; then
        log "ERROR: ollama not responding after 60s"
        start_gpu_containers
        return 1
    fi

    # Re-run the same model
    log "Running: ollama run $model"
    echo "" | ollama run "$model" --keepalive "$KEEPALIVE" &>/dev/null &
    sleep 15  # give it time to fully load into VRAM

    # Verify
    local verify_line
    verify_line=$(ollama ps 2>/dev/null | grep "^$model")
    local new_cpu
    new_cpu=$(get_cpu_pct "$verify_line")

    if [[ -z "$new_cpu" || "$new_cpu" -eq 0 ]]; then
        log "FIXED: $model is now fully on GPU"
        log_vram_snapshot "after successful reload"
        retry_counts[$model]=0
        start_gpu_containers
        return 0
    else
        log "STILL BAD: $model still showing ${new_cpu}% CPU"
        log_vram_snapshot "after failed reload"
        start_gpu_containers
        return 1
    fi
}

# ─── Main Loop ───────────────────────────────────────────────────────────────

log "=========================================="
log "Watchdog started (v1.1)"
log "  Container:       $CONTAINER_NAME"
log "  Check interval:  ${CHECK_INTERVAL}s"
log "  Max retries:     $MAX_RETRIES per model"
log "  Keepalive:       $KEEPALIVE"
log "  GPU containers:  ${GPU_CONTAINERS[*]}"
log "  Verbose level:   $VERBOSE"
log "  VRAM snapshots:  $VRAM_SNAPSHOTS"
log "=========================================="

# One-time check: warn if nvidia-smi is unavailable but snapshots are enabled
if [[ "$VRAM_SNAPSHOTS" -eq 1 ]] && ! command -v nvidia-smi &>/dev/null; then
    log "WARNING: VRAM_SNAPSHOTS=1 but nvidia-smi is not available. Snapshots will be skipped."
fi

while true; do
    log_debug "Running ollama ps check"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        model=$(echo "$line" | awk '{print $1}')
        cpu_pct=$(get_cpu_pct "$line")

        # Skip if fully on GPU or no CPU percentage found
        [[ -z "$cpu_pct" || "$cpu_pct" -eq 0 ]] && continue

        log "DETECTED: $model has ${cpu_pct}% CPU offload"
        log_vram_snapshot "at detection"

        retries=${retry_counts[$model]:-0}

        # Already gave up on this model
        [[ "$retries" -eq -1 ]] && continue

        if [[ "$retries" -ge "$MAX_RETRIES" ]]; then
            log "GIVING UP: $model failed $MAX_RETRIES times — likely not enough VRAM. Stopping model."
            ollama stop "$model" 2>/dev/null
            retry_counts[$model]=-1
            continue
        fi

        retry_counts[$model]=$((retries + 1))
        reload_model "$model" "${retry_counts[$model]}"

    done < <(ollama ps 2>/dev/null | tail -n +2)

    sleep "$CHECK_INTERVAL"
done
