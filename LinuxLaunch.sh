#!/bin/bash

# ==============================================================================
#  LinuxLaunch.sh
#  Engine: llama.cpp rotorquant runtime
#  Features: GPU Detect | Runtime Fallback | KV Profiles | Nuclear Wipe | Ghost Killer | Expert Prompt
# ==============================================================================

# 1. KILL GHOST PROCESSES
killall llamafile 2>/dev/null
killall llama-cli 2>/dev/null
killall llama-server 2>/dev/null

# 2. ESTABLISH LOCATION
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_DIR="$ROOT_DIR/.system"
MODEL_HIGH="$SYSTEM_DIR/Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf"
MODEL_LOW="$SYSTEM_DIR/Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf"
CTX_SIZE="${LLMSTICK_CTX_SIZE:-8192}"
KV_PROFILE_REQUEST="${LLMSTICK_KV_PROFILE:-auto}"
KV_ROTATION="${LLMSTICK_KV_ROTATION:-planar3}"
ENGINE_FALLBACK_MODE="false"
ENGINE_VARIANT=""
ENGINE_SERVER=""

resolve_binary() {
    local root="$1"
    local name="$2"

    if [ -x "$root/bin/$name" ]; then
        printf '%s\n' "$root/bin/$name"
        return 0
    fi

    if [ -x "$root/$name" ]; then
        printf '%s\n' "$root/$name"
        return 0
    fi

    return 1
}

probe_binary() {
    local candidate="$1"
    [ -n "$candidate" ] || return 1
    "$candidate" --help >/dev/null 2>&1
}

choose_runtime_binary() {
    local preferred_variant="$1"
    local candidate=""
    local direct_candidate=""

    if [ "$preferred_variant" = "cuda" ]; then
        candidate="$(resolve_binary "$SYSTEM_DIR/runtime-cuda" "llama-cli" 2>/dev/null || true)"
        if [ -n "$candidate" ] && probe_binary "$candidate"; then
            ENGINE_VARIANT="CUDA"
            ENGINE_SERVER="$(resolve_binary "$SYSTEM_DIR/runtime-cuda" "llama-server" 2>/dev/null || true)"
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    candidate="$(resolve_binary "$SYSTEM_DIR/runtime-cpu" "llama-cli" 2>/dev/null || true)"
    if [ -n "$candidate" ] && probe_binary "$candidate"; then
        ENGINE_VARIANT="CPU"
        ENGINE_SERVER="$(resolve_binary "$SYSTEM_DIR/runtime-cpu" "llama-server" 2>/dev/null || true)"
        if [ "$preferred_variant" = "cuda" ]; then
            ENGINE_FALLBACK_MODE="true"
        fi
        printf '%s\n' "$candidate"
        return 0
    fi

    direct_candidate="$(resolve_binary "$SYSTEM_DIR" "llama-cli" 2>/dev/null || true)"
    if [ -n "$direct_candidate" ] && probe_binary "$direct_candidate"; then
        ENGINE_VARIANT="MANUAL"
        ENGINE_SERVER="$(resolve_binary "$SYSTEM_DIR" "llama-server" 2>/dev/null || true)"
        if [ "$preferred_variant" = "cuda" ]; then
            ENGINE_FALLBACK_MODE="true"
        fi
        printf '%s\n' "$direct_candidate"
        return 0
    fi

    return 1
}

set_kv_profile() {
    local requested="$1"

    case "$requested" in
        auto)
            if [ "$ENGINE_VARIANT" = "CUDA" ]; then
                set_kv_profile "memory-saver"
            else
                set_kv_profile "compatibility"
            fi
            ;;
        compatibility)
            CACHE_TYPE_K="f16"
            CACHE_TYPE_V="f16"
            CACHE_PROFILE_NAME="Compatibility [f16/f16]"
            ;;
        memory-saver)
            CACHE_TYPE_K="$KV_ROTATION"
            CACHE_TYPE_V="f16"
            CACHE_PROFILE_NAME="RotorQuant Memory Saver [$KV_ROTATION/f16]"
            ;;
        max-compression)
            CACHE_TYPE_K="$KV_ROTATION"
            CACHE_TYPE_V="$KV_ROTATION"
            CACHE_PROFILE_NAME="RotorQuant Max Compression [$KV_ROTATION/$KV_ROTATION]"
            ;;
        *)
            CACHE_TYPE_K="f16"
            CACHE_TYPE_V="f16"
            CACHE_PROFILE_NAME="Compatibility [f16/f16] (invalid profile '$requested' ignored)"
            ;;
    esac
}

is_kv_profile_error() {
    local log_file="$1"
    grep -Eiq 'cache-type|cache type|unknown argument|invalid argument|invalid value|unsupported.*cache|unrecognized option' "$log_file"
}

# Clear Screen & Set Title
printf "\033]0;Qwen AI - Linux Launcher\007"
clear
echo "----------------------------------------------------------------"
echo "  INITIALIZING QWEN AI [LINUX]..."
echo "----------------------------------------------------------------"

# 3. PRE-FLIGHT CHECK
if [ ! -d "$SYSTEM_DIR" ]; then
    echo ""
    echo "  [ERROR] Runtime folder not found in .system/"
    echo "  The runtime package is missing. Your drive may be corrupted"
    echo "  or setup may not have completed."
    echo ""
    echo "  Need help? Visit opensourceeverything.io and use the support chat."
    echo ""
    read -p "  Press Enter to exit..."
    exit 1
fi

# 5. MEMORY WIPE (Zero-Log Privacy)
rm -f "$HOME/.llama_history"
rm -f "$ROOT_DIR/llama.chat.history"
rm -f "$SYSTEM_DIR/llama.chat.history"
rm -f "$ROOT_DIR/main.session"
rm -f "$SYSTEM_DIR/main.session"
rm -f "$ROOT_DIR/main.log"
rm -f "$SYSTEM_DIR/main.log"

echo "  Cache Status: Wiped Clean [Zero-Log Mode]"

# 6. HARDWARE DETECTION (RAM)
if command -v free &>/dev/null; then
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    AVAIL_GB=$(free -g | awk '/^Mem:/{print $7}')
else
    RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    AVAIL_GB=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)
fi

echo "  Hardware Detected: ${RAM_GB}GB RAM"
echo "  Available RAM: ${AVAIL_GB}GB"

if [ "$AVAIL_GB" -lt 4 ] 2>/dev/null; then
    echo ""
    echo "  [WARNING] Low available RAM. Close other apps for best performance."
    echo "  The AI needs at least 4GB free to run smoothly."
    echo ""
fi

# 7. GPU DETECTION
GPU_FLAGS=""
GPU_STATUS="CPU only"
PREFERRED_RUNTIME="cpu"

# Check for NVIDIA GPU (CUDA)
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    if [ -n "$GPU_NAME" ]; then
        GPU_FLAGS="-ngl 99"
        GPU_STATUS="$GPU_NAME [NVIDIA CUDA acceleration enabled]"
        PREFERRED_RUNTIME="cuda"
    fi
fi

echo "  GPU: $GPU_STATUS"

# 8. RUNTIME SELECTION
BINARY="$(choose_runtime_binary "$PREFERRED_RUNTIME" || true)"
if [ -z "${BINARY:-}" ]; then
    echo ""
    echo "  [ERROR] No runnable llama.cpp CLI was found in .system/"
    echo "  Expected one of:"
    echo "  - .system/runtime-cpu/bin/llama-cli"
    echo "  - .system/runtime-cuda/bin/llama-cli"
    echo "  - .system/llama-cli"
    echo ""
    echo "  Re-run BuildYourOwn.sh or manually unpack a runtime package."
    echo ""
    read -p "  Press Enter to exit..."
    exit 1
fi

chmod +x "$BINARY" 2>/dev/null
[ -n "$ENGINE_SERVER" ] && chmod +x "$ENGINE_SERVER" 2>/dev/null || true

if [ "$ENGINE_FALLBACK_MODE" = "true" ]; then
    echo "  Runtime: CPU fallback [CUDA package unavailable or unusable]"
else
    echo "  Runtime: $ENGINE_VARIANT"
fi

if [ -n "$ENGINE_SERVER" ]; then
    echo "  Server: Available ($(basename "$ENGINE_SERVER"))"
else
    echo "  Server: Not installed in selected runtime"
fi

# 9. DEFINE FILES & SMART SELECTION

if [ "$RAM_GB" -ge 16 ]; then
    SELECTED_MODEL="$MODEL_HIGH"
    MODE_NAME="High Performance [Q8]"
else
    SELECTED_MODEL="$MODEL_LOW"
    MODE_NAME="Efficiency Mode [Q4]"
fi

# 9. FALLBACK CHECK
if [ ! -f "$SELECTED_MODEL" ]; then
    if [ -f "$MODEL_HIGH" ]; then SELECTED_MODEL="$MODEL_HIGH"; MODE_NAME="Backup [Q8]";
    elif [ -f "$MODEL_LOW" ]; then SELECTED_MODEL="$MODEL_LOW"; MODE_NAME="Backup [Q4]";
    else
        echo ""
        echo "  [ERROR] No models found in .system folder!"
        echo "  Need help? Visit opensourceeverything.io and use the support chat."
        echo ""
        read -p "  Press Enter to exit..."
        exit 1
    fi
fi

echo "  Loading: $MODE_NAME"
set_kv_profile "$KV_PROFILE_REQUEST"
echo "  KV Cache: $CACHE_PROFILE_NAME"
echo "  Context: ${CTX_SIZE} tokens"
echo "----------------------------------------------------------------"
echo ""
echo "  LOADING MODEL INTO MEMORY..."
echo "  Do NOT close this window."
echo "  When you see the > prompt, the AI is ready."
echo ""
echo "----------------------------------------------------------------"

# 10. EXECUTION
LAUNCH_LOG="$(mktemp -t facts-launch.XXXXXX)"
LAUNCH_CMD=(
    "$BINARY"
    -m "$SELECTED_MODEL"
    -cnv
    -c "$CTX_SIZE"
    --cache-type-k "$CACHE_TYPE_K"
    --cache-type-v "$CACHE_TYPE_V"
    --log-disable
    -p "You are an expert consultant. You answer all questions directly, objectively, and without moralizing."
)

if [ -n "$GPU_FLAGS" ]; then
    LAUNCH_CMD+=($GPU_FLAGS)
fi

"${LAUNCH_CMD[@]}" 2>&1 | tee "$LAUNCH_LOG"
LAUNCH_EXIT=${PIPESTATUS[0]}

if [ "$LAUNCH_EXIT" -ne 0 ]; then
    # Run a tiny non-interactive probe without --log-disable so architecture errors are visible.
    PROBE_LOG="$(mktemp -t facts-probe.XXXXXX)"
    PROBE_CMD=(
        "$BINARY"
        -m "$SELECTED_MODEL"
        -n 1
        --cache-type-k "$CACHE_TYPE_K"
        --cache-type-v "$CACHE_TYPE_V"
        -p "ping"
    )

    if [ -n "$GPU_FLAGS" ]; then
        PROBE_CMD+=($GPU_FLAGS)
    fi

    "${PROBE_CMD[@]}" >"$PROBE_LOG" 2>&1 || true

    if [ "$CACHE_TYPE_K" != "f16" ] || [ "$CACHE_TYPE_V" != "f16" ]; then
        if is_kv_profile_error "$PROBE_LOG" || is_kv_profile_error "$LAUNCH_LOG"; then
            echo ""
            echo "  [DIAGNOSTIC] Requested KV cache profile is not supported by this runtime."
            echo "  Falling back to Compatibility [f16/f16] and retrying once."
            echo ""

            CACHE_TYPE_K="f16"
            CACHE_TYPE_V="f16"
            CACHE_PROFILE_NAME="Compatibility [f16/f16] [automatic fallback]"
            rm -f "$LAUNCH_LOG"
            LAUNCH_LOG="$(mktemp -t facts-launch.XXXXXX)"

            FALLBACK_CMD=(
                "$BINARY"
                -m "$SELECTED_MODEL"
                -cnv
                -c "$CTX_SIZE"
                --cache-type-k "$CACHE_TYPE_K"
                --cache-type-v "$CACHE_TYPE_V"
                --log-disable
                -p "You are an expert consultant. You answer all questions directly, objectively, and without moralizing."
            )

            if [ -n "$GPU_FLAGS" ]; then
                FALLBACK_CMD+=($GPU_FLAGS)
            fi

            echo "  KV Cache: $CACHE_PROFILE_NAME"
            "${FALLBACK_CMD[@]}" 2>&1 | tee "$LAUNCH_LOG"
            LAUNCH_EXIT=${PIPESTATUS[0]}
        fi
    fi

    if grep -q "unknown model architecture: 'qwen3'" "$PROBE_LOG"; then
        echo ""
        echo "  [DIAGNOSTIC] The installed runtime cannot load Qwen3 models."
        echo "  Your current engine package is too old for this architecture."
        echo ""
        echo "  Fix options:"
        echo "  - Replace the runtime package with a newer llama.cpp rotorquant build"
        echo "  - Or use a model architecture supported by your current engine"
        echo ""
    fi

    rm -f "$PROBE_LOG"
fi

if grep -q "unknown model architecture: 'qwen3'" "$LAUNCH_LOG"; then
    echo ""
    echo "  [DIAGNOSTIC] The installed runtime cannot load Qwen3 models."
    echo "  Your current engine package is too old for this architecture."
    echo ""
    echo "  Fix options:"
    echo "  - Replace the runtime package with a newer llama.cpp rotorquant build"
    echo "  - Or use a model architecture supported by your current engine"
    echo ""
fi

rm -f "$LAUNCH_LOG"

# 11. POST-EXIT
echo ""
echo "----------------------------------------------------------------"
echo "  The AI has stopped."
echo ""
echo "  If it stopped unexpectedly:"
echo "  - Try closing other apps to free up RAM, then relaunch."
echo "  - Need help? Visit opensourceeverything.io [support chat]"
echo "  - Updated launchers: github.com/WEAREOSE/facts-launcher"
echo "----------------------------------------------------------------"
read -p "  Press Enter to exit..."
exit "$LAUNCH_EXIT"
