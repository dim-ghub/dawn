#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DUSKY KOKORO INSTALLER V36 (AMD Fix + Model Precision + Final Polish)
# ==============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_DIR="$HOME/contained_apps/uv/dawn_kokoro"
readonly MODEL_DIR="$ENV_DIR/models"
readonly TRIGGER_DIR="$HOME/user_scripts/tts_stt/dawn_kokoro"
readonly TARGET_TRIGGER="$TRIGGER_DIR/trigger.sh"

readonly URL_F32="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
readonly URL_FP16="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.fp16.onnx"
readonly URL_INT8="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx"
readonly VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

echo ":: [V36] Initializing Dusky Kokoro Setup..."

# --- 1. Hardware Detection Report ---
echo "--------------------------------------------------------"
echo ":: Hardware Scan:"
GPU_FOUND=false

if command -v lspci &>/dev/null; then
    # Use text grep for classes "VGA", "3D", or "Display" to match reliable GPU markers
    if lspci | grep -E "VGA|3D|Display" | grep -i "nvidia" &>/dev/null; then
        echo "   [✓] NVIDIA GPU Detected"
        GPU_FOUND=true
    fi
    if lspci | grep -E "VGA|3D|Display" | grep -iE "amd|radeon" &>/dev/null; then
        echo "   [✓] AMD GPU Detected"
        GPU_FOUND=true
    fi
else
    echo "   [?] 'lspci' not found. Cannot auto-scan hardware."
fi

if [ "$GPU_FOUND" = false ]; then
    echo "   [!] No dedicated GPU detected (or unknown vendor)."
fi
echo "--------------------------------------------------------"

# --- 2. User Selection ---
echo "Select your installation target:"
echo "  1) NVIDIA (CUDA) - Best for GeForce/RTX cards"
echo "  2) AMD (ROCm)    - Best for Radeon/Instinct cards (Linux only)"
echo "  3) CPU Only      - Works everywhere, no GPU required (Lightweight)"
echo ""

# Fix: Initialize variable to prevent 'unbound variable' error on Ctrl+D
HW_CHOICE=""
read -p "Enter choice [1-3]: " HW_CHOICE || true

MODE="cpu"
if [[ "$HW_CHOICE" == "1" ]]; then
    MODE="nvidia"
elif [[ "$HW_CHOICE" == "2" ]]; then
    MODE="amd"
elif [[ "$HW_CHOICE" == "3" ]]; then
    MODE="cpu"
else
    echo ":: Invalid choice. Defaulting to CPU mode."
    MODE="cpu"
fi

echo ":: Selected Mode: ${MODE^^}"

# --- 2.5 Model Precision Selection ---
echo "--------------------------------------------------------"
echo "Select which Kokoro precision models to download:"
echo "  1) FP16 (169MB) - Recommended (Best balance of fidelity and VRAM)"
echo "  2) INT8 (88MB)  - Lightweight (Fastest, lowest VRAM)"
echo "  3) F32  (310MB) - Maximum Fidelity (Original uncompressed weights)"
echo "  4) ALL          - Download all three (Allows instant toggling in Python)"
echo ""

MODEL_CHOICE=""
read -p "Enter choice [1-4]: " MODEL_CHOICE || true

DL_FP16=false
DL_INT8=false
DL_F32=false

case "$MODEL_CHOICE" in
    1) DL_FP16=true; echo ":: Selected: FP16" ;;
    2) DL_INT8=true; echo ":: Selected: INT8" ;;
    3) DL_F32=true; echo ":: Selected: F32" ;;
    4) DL_FP16=true; DL_INT8=true; DL_F32=true; echo ":: Selected: ALL Models" ;;
    *) echo ":: Invalid choice. Defaulting to FP16."; DL_FP16=true ;;
esac
echo "--------------------------------------------------------"

# --- 3. Environment Setup ---
mkdir -p "$ENV_DIR" "$MODEL_DIR" "$TRIGGER_DIR"

if ! command -v uv &> /dev/null; then
    echo ":: Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    source "$HOME/.cargo/env"
fi

if [[ -f "$SCRIPT_DIR/dawn_main.py" ]]; then
    cp "$SCRIPT_DIR/dawn_main.py" "$ENV_DIR/"
    echo ":: dawn_main.py deployed."
else
    echo ":: ERROR: dawn_main.py not found in current directory."
    exit 1
fi

cd "$ENV_DIR"
echo ":: Configuring Python Environment..."
uv init --python 3.12 --no-workspace 2>/dev/null || true

# --- 4. Conditional Dependency Installation ---
echo ":: Installing Dependencies for $MODE..."

# Common base deps
uv add "soundfile" "numpy"

case "$MODE" in
    nvidia)
        # NVIDIA: kokoro-onnx[gpu] uses the [gpu] extra to pull onnxruntime-gpu correctly
        uv add "kokoro-onnx[gpu]" \
               "nvidia-cuda-runtime-cu12" \
               "nvidia-cublas-cu12" \
               "nvidia-cudnn-cu12" \
               "nvidia-cufft-cu12"
        ;;
    amd)
        # AMD: 
        # 1. Install kokoro-onnx (which pulls the standard CPU onnxruntime by default)
        uv add "kokoro-onnx"
        # 2. Force-install onnxruntime-rocm. 
        # We use 'uv pip install' to bypass the strict resolver and overwrite the CPU files.
        # This ensures the 'onnxruntime' import actually points to the ROCm-enabled binaries.
        echo ":: Forcing ROCm runtime installation..."
        uv pip install onnxruntime-rocm --force-reinstall --no-deps
        ;;
    cpu)
        # CPU: Standard runtime
        uv add "kokoro-onnx" "onnxruntime"
        ;;
esac

# --- 5. Model Downloads ---
if [[ "$DL_F32" == true && ! -f "$MODEL_DIR/kokoro-v1.0.onnx" ]]; then
    echo ":: Downloading F32 Model..."
    curl -L "$URL_F32" -o "$MODEL_DIR/kokoro-v1.0.onnx"
fi

if [[ "$DL_FP16" == true && ! -f "$MODEL_DIR/kokoro-v1.0.fp16.onnx" ]]; then
    echo ":: Downloading FP16 Model..."
    curl -L "$URL_FP16" -o "$MODEL_DIR/kokoro-v1.0.fp16.onnx"
fi

if [[ "$DL_INT8" == true && ! -f "$MODEL_DIR/kokoro-v1.0.int8.onnx" ]]; then
    echo ":: Downloading INT8 Model..."
    curl -L "$URL_INT8" -o "$MODEL_DIR/kokoro-v1.0.int8.onnx"
fi

if [[ ! -f "$MODEL_DIR/voices-v1.0.bin" ]]; then
    echo ":: Downloading Voices..."
    curl -L "$VOICES_URL" -o "$MODEL_DIR/voices-v1.0.bin"
fi

# --- 6. Generate Trigger ---
echo ":: Generating Trigger Script..."

cat << EOF > "$TARGET_TRIGGER"
#!/usr/bin/env bash
# Dusky Kokoro Trigger V36 ($MODE edition)
# Features: Universal HW, Robust Detection, Cold Boot Fix, Hard Kill, Base64 IPC

readonly APP_DIR="$HOME/contained_apps/uv/dawn_kokoro"
readonly PID_FILE="/tmp/dawn_kokoro.pid"
readonly READY_FILE="/tmp/dawn_kokoro.ready"
readonly FIFO_PATH="/tmp/dawn_kokoro.fifo"
readonly DAEMON_LOG="/tmp/dawn_kokoro.log"
readonly DEBUG_LOG="\$APP_DIR/dawn_debug.log"
readonly INSTALL_MODE="$MODE"

# --- Helpers ---

get_libs() {
    # NVIDIA-specific library discovery
    if [[ "\$INSTALL_MODE" == "nvidia" ]]; then
        local SITE_PACKAGES
        SITE_PACKAGES=\$(find "\$APP_DIR/.venv" -type d -name "site-packages" 2>/dev/null | head -n 1)
        if [[ -n "\$SITE_PACKAGES" && -d "\$SITE_PACKAGES/nvidia" ]]; then
            local libs
            libs=\$(find "\$SITE_PACKAGES/nvidia" -type d -name "lib" | tr '\n' ':')
            echo "\${libs%:}"
        fi
    fi
}

notify() { notify-send "\$@" 2>/dev/null || true; }

is_running() {
    [[ -f "\$PID_FILE" ]] && kill -0 "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null
}

stop_daemon() {
    if [[ -f "\$PID_FILE" ]]; then
        local pid
        pid=\$(cat "\$PID_FILE" 2>/dev/null)
        if [[ -n "\$pid" ]]; then
            kill "\$pid" 2>/dev/null || true
            for _ in {1..30}; do
                kill -0 "\$pid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "\$pid" 2>/dev/null; then
                echo ":: Daemon stuck. Force killing..."
                kill -9 "\$pid" 2>/dev/null || true
            fi
        fi
    fi
    rm -f "\$PID_FILE" "\$FIFO_PATH" "\$READY_FILE"
}

start_daemon() {
    local debug_mode="\${1:-false}"

    if ! command -v mpv &>/dev/null; then
        notify "Kokoro Error" "MPV is missing!"
        return 1
    fi

    local EXTRA_LIBS
    EXTRA_LIBS=\$(get_libs)
    if [[ -n "\$EXTRA_LIBS" ]]; then
        export LD_LIBRARY_PATH="\${EXTRA_LIBS}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    fi

    cd "\$APP_DIR"

    if [[ "\$debug_mode" == "true" ]]; then
        echo ":: Starting Daemon in FORENSIC DEBUG Mode..."
        export DUSKY_LOG_LEVEL="DEBUG"
        export DUSKY_LOG_FILE="\$DEBUG_LOG"
        nohup uv run dawn_main.py --daemon --debug-file "\$DEBUG_LOG" > "\$DAEMON_LOG" 2>&1 &
    else
        nohup uv run dawn_main.py --daemon > "\$DAEMON_LOG" 2>&1 &
    fi

    # IMMEDIATE PID LOCK: Prevents double-start during cold boot
    local daemon_pid=\$!
    echo "\$daemon_pid" > "\$PID_FILE"

    # Wait for daemon ready (30s timeout covers cold boot)
    for _ in {1..300}; do
        if [[ -f "\$READY_FILE" ]]; then
            if [[ "\$debug_mode" == "true" ]]; then
                echo ":: Daemon Ready. Tailing log..."
                tail -f "\$DEBUG_LOG"
            fi
            return 0
        fi
        if ! kill -0 "\$daemon_pid" 2>/dev/null; then
            echo ":: ERROR: Daemon process died during startup."
            notify "Kokoro Failed" "Daemon crashed during startup."
            return 1
        fi
        sleep 0.1
    done

    echo ":: ERROR: Daemon start timeout (30s)."
    notify "Kokoro Failed" "Daemon start timeout."
    return 1
}

show_help() {
    cat << 'HELP'
Dusky Kokoro TTS — Trigger Script

USAGE:
    trigger.sh              Send clipboard text to TTS (starts daemon if needed)
    trigger.sh [OPTION]

OPTIONS:
    --help, -h       Show this help
    --kill           Stop the daemon
    --restart        Restart the daemon
    --status         Check if daemon is running
    --debug          Restart in debug mode (tails verbose log)
    --logs           Tail the daemon log
HELP
}

# --- CLI Logic ---
case "\${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --kill)
        if is_running; then
            stop_daemon
            echo ":: Daemon stopped."
        else
            echo ":: Daemon not running (cleaning stale files)."
            rm -f "\$PID_FILE" "\$FIFO_PATH" "\$READY_FILE"
        fi
        exit 0
        ;;
    --status)
        if is_running; then 
            echo ":: Daemon running (PID: \$(cat "\$PID_FILE"))"
        else 
            echo ":: Daemon not running."
        fi
        exit 0
        ;;
    --restart)
        echo ":: Restarting daemon..."
        stop_daemon
        start_daemon "false"
        exit \$?
        ;;
    --logs)
        if [[ -f "\$DAEMON_LOG" ]]; then
            tail -f "\$DAEMON_LOG"
        else
            echo ":: No log file at \$DAEMON_LOG"
        fi
        exit 0
        ;;
    --debug)
        if is_running; then
            echo ":: Stopping existing daemon..."
            stop_daemon
        fi
        start_daemon "true"
        exit \$?
        ;;
    --*)
        echo ":: Unknown flag: \$1"
        echo ":: Use '\$(basename "\$0") --help' for usage."
        exit 1
        ;;
    "")
        ;;
    *)
        echo ":: Unknown argument: \$1"
        exit 1
        ;;
esac

# --- Trigger Logic ---

# Ensure running
if ! is_running; then
    rm -f "\$FIFO_PATH" "\$PID_FILE" "\$READY_FILE"
    if ! start_daemon "false"; then exit 1; fi
fi

# Secondary readiness gate
if [[ ! -f "\$READY_FILE" ]]; then
    for _ in {1..300}; do
        if [[ -f "\$READY_FILE" ]]; then break; fi
        if ! is_running; then
            echo ":: ERROR: Daemon died while waiting for readiness."
            notify "Kokoro Failed" "Daemon died during startup."
            exit 1
        fi
        sleep 0.1
    done
    if [[ ! -f "\$READY_FILE" ]]; then
        echo ":: ERROR: Daemon readiness timeout (30s)."
        notify "Kokoro Failed" "Daemon not ready."
        exit 1
    fi
fi

# Send Clipboard via Base64 to preserve absolute formatting across the FIFO pipe
INPUT_TEXT=\$(timeout 2 wl-paste 2>/dev/null || true)
if [[ -n "\$INPUT_TEXT" ]]; then
    B64_TEXT=\$(printf '%s' "\$INPUT_TEXT" | base64 -w 0)

    printf 'B64:%s\n' "\$B64_TEXT" > "\$FIFO_PATH" &
    WRITE_PID=\$!
    
    WRITE_OK=false
    for _ in {1..20}; do
        if ! kill -0 "\$WRITE_PID" 2>/dev/null; then
            wait "\$WRITE_PID" 2>/dev/null && WRITE_OK=true
            break
        fi
        sleep 0.1
    done
    
    if \$WRITE_OK; then
        notify -t 1000 "Kokoro" "Processing..."
    else
        kill "\$WRITE_PID" 2>/dev/null || true
        wait "\$WRITE_PID" 2>/dev/null || true
        notify "Kokoro Error" "Daemon Unresponsive"
    fi
else
    notify "Kokoro" "Clipboard empty"
fi
EOF

chmod +x "$TARGET_TRIGGER"
echo ":: Setup Complete. Trigger script installed at:"
echo "   $TARGET_TRIGGER"
