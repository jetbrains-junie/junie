#!/bin/sh
set -e

# ============================================================
# Command-line arguments
# ============================================================

PROTOCOL_VERSION=1

MACHINE_OUTPUT=false
CHECK_ONLY=false
KEEP_CONFIG=false
MODEL="qwen3.6"

usage() {
  echo "Usage: install.sh [options]"
  echo ""
  echo "Options:"
  echo "  --model <name>     Model to install: qwen3.6 (default) or qwen3.8"
  echo "  --check-only       Report system information and install configuration, then exit"
  echo "  --json             Emit machine-readable events on stdout, human output on stderr"
  echo "  --keep-config      Preserve the existing server-config.json instead of removing it"
  echo "  --help, -h         Show this help"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MACHINE_OUTPUT=true ;;
    --check-only) CHECK_ONLY=true ;;
    --keep-config) KEEP_CONFIG=true ;;
    --model)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: --model requires a value"; usage; exit 1
      fi
      MODEL="$1"
      ;;
    --model=*) MODEL="${1#--model=}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ "$MACHINE_OUTPUT" = true ]; then
  # stdout carries only machine events; human-oriented output goes to stderr
  exec 3>&1 1>&2
fi

# ============================================================
# Configuration
# ============================================================

BASE_URL="https://download.jetbrains.com/resources/junie-local"
BASE_DIR="$HOME/.local/share/junie-local"
# Junie configuration directory; the caller (Junie CLI) overrides it when it
# runs with a non-default home so the model config lands where that instance
# looks for it.
JUNIE_HOME="${JUNIE_HOME:-$HOME/.junie}"
MODELS_DIR="$BASE_DIR/models"
DOWNLOAD_DIR="$BASE_DIR/incomplete_downloads"

# Model archives, their SHA256 checksums, model IDs, and display labels.
# Both variants are published side by side; --model picks the one to install,
# and installing one leaves an already installed other one untouched.
case "$MODEL" in
  qwen3.6)
    MODEL_ZIP_1="Qwen3.6-27B-MLX-4bit.zip"
    MODEL_SHA256_1="d8abf8f9260247fe2d571b5b65a5d6b80da6635f74f5e2ca195da1941ca7d48d"
    MODEL_ID_1="Qwen3.6-27B-MLX-4bit"
    MODEL_LABEL_1="Qwen 3.6 27B 4bit"
    MODEL_ZIP_2="Qwen3.6-27B-MTP-MLX-4bit.zip"
    MODEL_SHA256_2="ebbef3755e836082837f902036bfedb8201ab353310f3cbaefdb6d7b652b980f"
    MODEL_ID_2="Qwen3.6-27B-MTP-MLX-4bit"
    MODEL_LABEL_2="MTP draft model"
    JUNIE_MODEL_ID="local-qwen3.6-27b-4bit"
    JUNIE_MODEL_DISPLAY_NAME="Qwen 3.6"
    ;;
  qwen3.8)
    MODEL_ZIP_1="Qwen3.8-27B-MLX-4bit.zip"
    MODEL_SHA256_1="50e659f4d286e281502aeaa0fbea43710fd318a976c8cd331c1f8519b303ba39"
    MODEL_ID_1="Qwen3.8-27B-MLX-4bit"
    MODEL_LABEL_1="Qwen 3.8 27B 4bit"
    MODEL_ZIP_2="Qwen3.8-27B-MTP-MLX-4bit.zip"
    MODEL_SHA256_2="3131d15127297d26c5e97ab63e242be5d1a81b3c8a390fa6e5b6e5a08d7f4f90"
    MODEL_ID_2="Qwen3.8-27B-MTP-MLX-4bit"
    MODEL_LABEL_2="MTP draft model"
    JUNIE_MODEL_ID="local-qwen3.8-27b-4bit"
    JUNIE_MODEL_DISPLAY_NAME="Qwen 3.8"
    ;;
  *)
    echo "ERROR: Unknown model: $MODEL (supported: qwen3.6, qwen3.8)"
    exit 1
    ;;
esac

# Name the engine serves the main model under. It matches the directory the
# archive unpacks into under $MODELS_DIR.
ENGINE_MODEL_NAME="$MODEL_ID_1"

# Inference engine release. Versions are unpacked side by side under versions/
# and the current symlink points at the one to run.
ENGINE_VERSION="0.2.2"
ENGINE_ARCHIVE="junie-mlx-vlm-0.2.2-macos-arm64.tar.gz"
ENGINE_URL="https://cache-redirector.jetbrains.com/github.com/JetBrains-Hardware/junie-local/releases/download/v0.2.2/$ENGINE_ARCHIVE"
ENGINE_SHA256="21181744477202f37caed57874ae2bbb5c083816ae084553b1fba3dd978c5763"
ENGINE_LABEL="inference engine"
VERSIONS_DIR="$BASE_DIR/versions"
ENGINE_DIR="$VERSIONS_DIR/$ENGINE_VERSION"
CURRENT_LINK="$BASE_DIR/current"
ENGINE_BIN="$CURRENT_LINK/junie-mlx-vlm"
ENGINE_CTL="$CURRENT_LINK/serverctl.sh"
ENGINE_DAEMON_LOG="$BASE_DIR/junie-mlx-vlm-daemon.log"

# The port the engine serves on (the Junie model config below points at it) and
# the RAM allowance it may spend on weights and KV cache. The engine reads the
# rest of its settings from $BASE_DIR/server-config.json, which it writes itself
# on first start. Nothing here consumes the RAM allowance yet — it is only
# displayed and reported in the "config" event.
ENGINE_PORT=19239
ENGINE_RAM_GB=35

# Bearer auth token for local engine-to-Junie communication. Generated on first
# install and stored in server-config.json (api_key field). On re-runs the
# installer reads the existing token from server-config.json to keep it stable.
AUTH_TOKEN=""

# Junie model configuration. The id and display name come from the selected
# model above, so each variant gets its own config file in $JUNIE_HOME/models.
JUNIE_CUSTOM_MODEL_ID="custom:$JUNIE_MODEL_ID"
JUNIE_MODEL_PROVIDER_NAME="Local"
# seems to be optimal context length
JUNIE_MAX_CONTEXT_LENGTH=150000

# ============================================================
# Machine-readable events (--json): one JSON object per line on stdout
#   {"event":"hello","protocol":1}
#   {"event":"check","name":"os|cpu|ram","status":"ok|warn|fail","value":"...","requirement":"..."}
#   {"event":"config","port":N,"ram_gb":N,"engine_version":"...","model":"...","checks_passed":true|false}
#   {"event":"step_start","id":"engine|models|configure|start","title":"..."}
#   {"event":"progress","action":"downloading|extracting","file":"...","bytes":N,"total":N,"label":"..."}
#   {"event":"activity","action":"verifying|extracting","file":"...","label":"..."}
#   {"event":"step_done","id":"engine|models|configure|start"}
#   {"event":"warning","message":"..."}
#   {"event":"error","message":"..."}
#   {"event":"done","model_id":"...","port":N,"model_path":"...","label":"..."}
# Consumers must check the protocol version in "hello" and ignore
# unknown event types and fields.
# ============================================================

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_event() {
  if [ "$MACHINE_OUTPUT" = true ]; then
    printf '{%s}\n' "$1" >&3
  fi
}

emit_check() {
  emit_event "\"event\":\"check\",\"name\":\"$1\",\"status\":\"$2\",\"value\":\"$(json_escape "$3")\",\"requirement\":\"$(json_escape "$4")\""
}

emit_step_start() {
  emit_event "\"event\":\"step_start\",\"id\":\"$1\",\"title\":\"$(json_escape "$2")\""
}

emit_step_done() {
  emit_event "\"event\":\"step_done\",\"id\":\"$1\""
}

emit_progress() {
  emit_event "\"event\":\"progress\",\"action\":\"${5:-downloading}\",\"file\":\"$(json_escape "$1")\",\"bytes\":${2:-0},\"total\":${3:-0},\"label\":\"$(json_escape "$4")\""
}

emit_activity() {
  emit_event "\"event\":\"activity\",\"action\":\"$1\",\"file\":\"$(json_escape "$2")\",\"label\":\"$(json_escape "$3")\""
}

emit_warning() {
  emit_event "\"event\":\"warning\",\"message\":\"$(json_escape "$1")\""
}

emit_error() {
  emit_event "\"event\":\"error\",\"message\":\"$(json_escape "$1")\""
}

# Map an ok/warn flag pair to a check status
check_status() {
  if [ "$1" != true ]; then
    echo "fail"
  elif [ "$2" = true ]; then
    echo "warn"
  else
    echo "ok"
  fi
}

emit_event "\"event\":\"hello\",\"protocol\":$PROTOCOL_VERSION"

# Helper: wait for user to press any key, then exit
wait_and_exit() {
  if [ "$MACHINE_OUTPUT" != true ]; then
    echo ""
    echo "Press any key to exit..."
    # If read fails, still exit with the intended code (not read's status)
    read -r -n 1 || true
  fi
  exit "$1"
}

# ============================================================
# Collect system information
# ============================================================

# OS detection
UNAME_OUT=$(uname -s)
OS_FULL_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
OS_VERSION=$(echo "$OS_FULL_VERSION" | cut -d '.' -f 1)

# CPU model
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")

# Total memory in GB
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEM_GB=$((MEM_BYTES / 1073741824))

# ============================================================
# System info summary: evaluate & display
# ============================================================
echo "=== Junie Local Model Installer ==="
echo ""
echo "=== System Information ==="
echo ""

# ANSI color helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

if [ "$MACHINE_OUTPUT" = true ]; then
  GREEN=''
  RED=''
  YELLOW=''
  NC=''
fi

# Helper: print a value in green if ok, yellow if warning, red if not ok
print_value() {
  label="$1"
  value="$2"
  ok="$3"
  warn="$4"
  requirement="$5"
  if [ "$ok" = true ] && [ "$warn" = false ]; then
    printf "  %-20s ${GREEN}%s${NC}\n" "$label" "$value"
  elif [ "$warn" = true ]; then
    printf "  %-20s ${YELLOW}%s${NC}  (%s)\n" "$label" "$value" "$requirement"
  else
    printf "  %-20s ${RED}%s${NC}  (requirement: %s)\n" "$label" "$value" "$requirement"
  fi
}

ALL_OK=true

# OS check (hard requirement: macOS 26+)
OS_OK=true
if [ "$UNAME_OUT" != "Darwin" ]; then
  OS_OK=false
  ALL_OK=false
elif [ "$OS_VERSION" -lt 26 ]; then
  OS_OK=false
  ALL_OK=false
fi
if [ "$UNAME_OUT" = "Darwin" ]; then
  OS_DISPLAY="macOS $OS_FULL_VERSION"
else
  OS_DISPLAY="$UNAME_OUT $OS_FULL_VERSION"
fi
print_value "OS:" "$OS_DISPLAY" "$OS_OK" false "macOS 26 or higher"
emit_check "os" "$(check_status "$OS_OK" false)" "$OS_DISPLAY" "macOS 26 or higher"
echo ""

# CPU check (hard: Apple Silicon, recommended: M4 or M5)
CPU_OK=true
CPU_WARN=false
case "$CPU_MODEL" in
  *M4*|*M5*)
    # Fully recommended
    ;;
  *M*)
    # Has Apple Silicon but not M4/M5 — acceptable with warning
    CPU_WARN=true
    ;;
  *)
    # No Apple Silicon — hard fail
    CPU_OK=false
    ALL_OK=false
    ;;
esac
print_value "CPU:" "$CPU_MODEL" "$CPU_OK" "$CPU_WARN" "M4 or M5 recommended"
emit_check "cpu" "$(check_status "$CPU_OK" "$CPU_WARN")" "$CPU_MODEL" "M4 or M5 recommended"
echo ""

# RAM check (hard: >= 40 GB, recommended: >= 60 GB)
RAM_OK=true
RAM_WARN=false
if [ "$MEM_GB" -lt 40 ]; then
  RAM_OK=false
  ALL_OK=false
elif [ "$MEM_GB" -lt 60 ]; then
  RAM_WARN=true
fi
print_value "RAM:" "${MEM_GB} GB" "$RAM_OK" "$RAM_WARN" "minimum 40 GB, 60 GB recommended"
emit_check "ram" "$(check_status "$RAM_OK" "$RAM_WARN")" "${MEM_GB} GB" "minimum 40 GB, 60 GB recommended"
echo ""

# Install Configuration section
echo "=== Install Configuration ==="
echo ""

print_value "Engine:" "junie-mlx-vlm v${ENGINE_VERSION}" true false ""
print_value "Model:" "$MODEL" true false ""
print_value "Models directory:" "$MODELS_DIR" true false ""
print_value "Junie home:" "$JUNIE_HOME" true false ""
print_value "Inference port:" "$ENGINE_PORT" true false ""
print_value "RAM allowance:" "${ENGINE_RAM_GB} GB" true false ""
echo ""

emit_event "\"event\":\"config\",\"port\":$ENGINE_PORT,\"ram_gb\":$ENGINE_RAM_GB,\"engine_version\":\"$(json_escape "$ENGINE_VERSION")\",\"model\":\"$(json_escape "$MODEL")\",\"checks_passed\":$ALL_OK"

if [ "$CHECK_ONLY" = true ]; then
  if [ "$ALL_OK" = true ]; then
    exit 0
  else
    exit 1
  fi
fi

# ============================================================
# Abort unless all hard requirements are met
# ============================================================
if [ "$ALL_OK" = false ]; then
  echo "Some system requirements are not met. Installation cannot proceed."
  emit_error "Some system requirements are not met. Installation cannot proceed."
  wait_and_exit 1
fi

# Cleanup function — kills child processes on interrupt
cleanup() {
  exit_code="$1"

  # Avoid executing this trap recursively.
  trap - INT TERM

  echo ""
  if [ -d "$DOWNLOAD_DIR" ]; then
    echo "Interrupted — partial downloads preserved in $DOWNLOAD_DIR"
    echo "Re-run this script to resume."
    emit_error "Interrupted — partial downloads preserved, re-run to resume"
  else
    echo "Interrupted."
    emit_error "Interrupted"
  fi

  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true

  wait_and_exit "$exit_code"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# Create directories
echo "Creating directories..."
mkdir -p "$MODELS_DIR"
mkdir -p "$VERSIONS_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Download while emitting progress events, polling the output file size.
# The total comes from a HEAD request; with resumed downloads the file size
# is absolute, so bytes/total stays correct across re-runs.
download_with_progress_events() {
  url="$1"
  output_file="$2"
  label="$3"
  file_name=$(basename "$output_file")

  total=$(curl -sIL "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { len = $2 } END { print len + 0 }')

  curl -sSL -C - -o "$output_file" "$url" &
  download_pid=$!
  while kill -0 "$download_pid" 2>/dev/null; do
    bytes=$(stat -f %z "$output_file" 2>/dev/null || echo 0)
    emit_progress "$file_name" "$bytes" "$total" "$label"
    sleep 1
  done
  if wait "$download_pid"; then
    emit_progress "$file_name" "$(stat -f %z "$output_file" 2>/dev/null || echo 0)" "$total" "$label"
    return 0
  fi
  return 1
}

# Extract a zip while emitting progress events, polling the unpacked size on
# disk against the archive's uncompressed total (from its central directory).
extract_with_progress_events() {
  archive="$1"
  dest_dir="$2"
  label="$3"
  file_name=$(basename "$archive")

  total=$(unzip -l "$archive" 2>/dev/null | tail -1 | awk '{print $1 + 0}')

  unzip -q "$archive" -d "$MODELS_DIR" &
  unzip_pid=$!
  while kill -0 "$unzip_pid" 2>/dev/null; do
    # The destination directory does not exist until unzip creates it, so `du`
    # can fail — `awk END` still prints a number, keeping the arithmetic valid.
    extracted_kb=$(du -sk "$dest_dir" 2>/dev/null | awk 'END { print $1 + 0 }')
    bytes=$(( ${extracted_kb:-0} * 1024 ))
    emit_progress "$file_name" "$bytes" "$total" "$label" "extracting"
    sleep 1
  done
  wait "$unzip_pid"
}

# Function to download a file with retry logic and exponential backoff
# Usage: download_with_retry <url> <output_file> <label> [max_retries]
download_with_retry() {
  url="$1"
  output_file="$2"
  dl_label="$3"
  max_retries="${4:-3}"
  attempt=1
  delay=2

  while [ "$attempt" -le "$max_retries" ]; do
    echo "  Attempt $attempt of $max_retries..."
    if [ "$MACHINE_OUTPUT" = true ]; then
      if download_with_progress_events "$url" "$output_file" "$dl_label"; then
        return 0
      fi
    elif curl --progress-bar -SL -C - -o "$output_file" "$url"; then
      return 0
    fi

    if [ "$attempt" -lt "$max_retries" ]; then
      echo "  Download failed. Retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  echo "  ERROR: Download failed after $max_retries attempts."
  emit_error "Download failed after $max_retries attempts"
  return 1
}

# Check if an engine version has been fully unpacked. As with the models, a
# completion marker is written after unpacking — a version directory without it
# is a leftover from an interrupted run.
engine_completion_marker() {
  echo "$VERSIONS_DIR/.$ENGINE_VERSION.installed"
}

engine_installed() {
  [ -x "$ENGINE_DIR/junie-mlx-vlm" ] && [ -f "$ENGINE_DIR/serverctl.sh" ] && [ -f "$(engine_completion_marker)" ]
}

# Function to download and unpack the inference engine, then point current at it
install_engine() {
  if engine_installed; then
    echo "  Engine v$ENGINE_VERSION is already unpacked. Skipping download."
  else
    echo "  Downloading $ENGINE_ARCHIVE..."
    download_with_retry "$ENGINE_URL" "$DOWNLOAD_DIR/$ENGINE_ARCHIVE" "$ENGINE_LABEL"
    echo "  Download complete. Checking SHA256..."

    emit_activity "verifying" "$ENGINE_ARCHIVE" "$ENGINE_LABEL"
    actual_sha256=$(shasum -a 256 "$DOWNLOAD_DIR/$ENGINE_ARCHIVE" | awk '{print $1}')
    if [ "$actual_sha256" != "$ENGINE_SHA256" ]; then
      echo "  ERROR: SHA256 mismatch for $ENGINE_ARCHIVE"
      echo "    Expected: $ENGINE_SHA256"
      echo "    Actual:   $actual_sha256"
      emit_error "SHA256 mismatch for $ENGINE_ARCHIVE"
      wait_and_exit 1
    fi
    echo "  SHA256 verified: $actual_sha256"

    echo "  Unpacking to $ENGINE_DIR..."
    emit_activity "extracting" "$ENGINE_ARCHIVE" "$ENGINE_LABEL"
    # Remove leftovers from a previously interrupted unpack
    rm -rf "$ENGINE_DIR"
    mkdir -p "$ENGINE_DIR"
    # The archive holds a single junie-mlx-vlm/ directory; strip it so the
    # binary lands directly in the version directory
    tar -xzf "$DOWNLOAD_DIR/$ENGINE_ARCHIVE" -C "$ENGINE_DIR" --strip-components=1
    touch "$(engine_completion_marker)"
    rm -f "$DOWNLOAD_DIR/$ENGINE_ARCHIVE"
    echo "  Unpack complete."
  fi

  # A real directory at current would make ln fail — refuse rather than delete it
  if [ -d "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
    echo "  ERROR: $CURRENT_LINK is a directory, not a symlink."
    echo "  Move it out of the way and re-run."
    emit_error "$CURRENT_LINK is a directory, not a symlink"
    wait_and_exit 1
  fi

  echo "  Pointing $CURRENT_LINK at $ENGINE_DIR..."
  ln -sfn "$ENGINE_DIR" "$CURRENT_LINK"
  echo ""
}

# Generate a random bearer token: "sk-" plus 12 random bytes in hex.
generate_auth_token() {
  AUTH_TOKEN=$(printf 'sk-%s' "$(head -c 12 /dev/urandom | xxd -p)")
  echo "  Auth token generated."
}

# Read the bearer token from an existing server-config.json using plutil.
read_auth_token_from_server_config() {
  SERVER_CONFIG="$BASE_DIR/server-config.json"
  if [ -f "$SERVER_CONFIG" ]; then
    AUTH_TOKEN=$(plutil -extract api_key raw "$SERVER_CONFIG" 2>/dev/null || true)
  fi
}

# Write server-config.json with the api_key field set to the generated bearer
# token. The engine will read this on startup and enforce auth on all endpoints.
# With --keep-config the previous file is left in place.
handle_server_config() {
  SERVER_CONFIG="$BASE_DIR/server-config.json"

  # On re-run, try to read the existing token from server-config.json before
  # removing it, so we can reuse it in the fresh config.
  if [ -z "$AUTH_TOKEN" ] && [ -f "$SERVER_CONFIG" ]; then
    read_auth_token_from_server_config
  fi

  if [ -f "$SERVER_CONFIG" ]; then
    if [ "$KEEP_CONFIG" = true ]; then
      echo "  Keeping existing server-config.json (--keep-config)."
    else
      echo "  Removing existing server-config.json (use --keep-config to preserve)."
      rm -f "$SERVER_CONFIG"
    fi
  fi

  if [ -z "$AUTH_TOKEN" ]; then
    generate_auth_token
  fi

  if [ "$KEEP_CONFIG" != true ]; then
    echo "  Writing server-config.json with api_key..."
    cat > "$SERVER_CONFIG" <<EOF
{
  "api_key": "$AUTH_TOKEN"
}
EOF
    echo "  server-config.json created with bearer auth."
  fi
}

# Function to start the engine daemon using serverctl.sh. The daemon serves the
# public API and supervises the inference worker itself.
start_engine() {
  # Remove the config file by default so the engine writes a fresh one on first start.
  handle_server_config

  if [ ! -x "$ENGINE_BIN" ]; then
    echo "  WARNING: engine binary not found at $ENGINE_BIN"
    echo "  Skipping engine startup."
    emit_warning "engine binary not found at $ENGINE_BIN — start it manually"
    return 1
  fi

  if [ ! -f "$ENGINE_CTL" ]; then
    echo "  WARNING: serverctl.sh not found at $ENGINE_CTL — falling back to direct start"
    emit_warning "serverctl.sh missing — using direct binary start"
  fi

  # Stop an engine from an earlier run so it releases the port
  if pgrep -f junie-mlx-vlm > /dev/null 2>&1; then
    echo "  Stopping the running engine..."
    if [ -f "$ENGINE_CTL" ]; then
      "$ENGINE_CTL" stop >/dev/null 2>&1 || true
    else
      pkill -f junie-mlx-vlm || true
    fi
    waited=0
    while [ "$waited" -lt 10 ] && pgrep -f junie-mlx-vlm > /dev/null 2>&1; do
      sleep 1
      waited=$((waited + 1))
    done
  fi

  # Start via serverctl.sh (the subshell keeps the daemon out of this script's
  # job table so the interrupt handler cannot take it down with the installer).
  # 3>&- keeps the spawned daemon from inheriting the machine-output event
  # stream: a consumer reading our stdout would otherwise never see
  # end-of-stream because the daemon holds the pipe open forever.
  echo "  Starting the engine (log: $ENGINE_DAEMON_LOG)..."
  if [ -f "$ENGINE_CTL" ]; then
    ( "$ENGINE_CTL" start > /dev/null 2>&1 3>&- )
  else
    ( nohup "$ENGINE_BIN" daemon < /dev/null >> "$ENGINE_DAEMON_LOG" 2>&1 3>&- & )
  fi

  # Wait for the engine to become ready. serverctl.sh wait polls /status until
  # phase is "ready"; fall back to a simple port check if it is unavailable.
  if [ -f "$ENGINE_CTL" ]; then
    waited=0
    while [ "$waited" -lt 30 ]; do
      phase=$(curl -s -m 5 "http://localhost:$ENGINE_PORT/status" 2>/dev/null \
        | plutil -extract phase raw -o - -- - 2>/dev/null || true)
      if [ "$phase" = "ready" ]; then
        echo "  Engine is ready on port $ENGINE_PORT."
        return 0
      fi
      if [ "$phase" = "error" ]; then
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
  else
    waited=0
    while [ "$waited" -lt 26 ]; do
      if nc -z localhost "$ENGINE_PORT" 2>/dev/null; then
        echo "  Engine is listening on port $ENGINE_PORT."
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
  fi

  echo "  WARNING: the engine is not answering on port $ENGINE_PORT yet."
  echo "  Check the log at $ENGINE_DAEMON_LOG"
  emit_warning "engine did not start listening on port $ENGINE_PORT — see $ENGINE_DAEMON_LOG"
  return 1
}

# Function to create Junie model config file with bearer auth
create_junie_model_config() {
  JUNIE_MODELS_DIR="$JUNIE_HOME/models"
  JUNIE_CONFIG_FILE="$JUNIE_MODELS_DIR/${JUNIE_MODEL_ID}.json"

  # Create the models directory if it doesn't exist
  if [ ! -d "$JUNIE_MODELS_DIR" ]; then
    mkdir -p "$JUNIE_MODELS_DIR"
  fi

  # Ensure the auth token is available; if handle_server_config already ran,
  # AUTH_TOKEN is already set. Otherwise read from server-config.json or generate.
  if [ -z "$AUTH_TOKEN" ]; then
    read_auth_token_from_server_config
  fi
  if [ -z "$AUTH_TOKEN" ]; then
    generate_auth_token
  fi

  # Write the Junie model config with the bearer token as apiKey.
  echo "  Creating Junie model config at $JUNIE_CONFIG_FILE..."
  cat > "$JUNIE_CONFIG_FILE" <<EOF
{
  "displayName": "$JUNIE_MODEL_DISPLAY_NAME",
  "providerName": "$JUNIE_MODEL_PROVIDER_NAME",
  "id": "$ENGINE_MODEL_NAME",
  "baseUrl": "http://localhost:$ENGINE_PORT/v1/chat/completions",
  "apiType": "OpenAICompletion",
  "apiKey": "$AUTH_TOKEN",
  "temperature": 0.6,
  "maxContextLength": $JUNIE_MAX_CONTEXT_LENGTH,
  "extraBody": {
    "enable_thinking": false
  }
}
EOF
  echo "  Junie model config created with bearer auth."
  return 0
}

# Function to set the local model as the default in Junie settings
set_default_junie_model() {
  JUNIE_SETTINGS="$JUNIE_HOME/settings.json"

  if [ ! -f "$JUNIE_SETTINGS" ]; then
    echo "  WARNING: Junie settings not found at $JUNIE_SETTINGS"
    echo "  Skipping default model configuration."
    emit_warning "Junie settings not found — the local model was not set as default"
    return 1
  fi

  echo "  Setting local model as default in Junie..."
  plutil -replace "modelForLaunch" -string "$JUNIE_CUSTOM_MODEL_ID" "$JUNIE_SETTINGS"
  echo "  Default model set to $JUNIE_MODEL_ID."
  return 0
}

# ============================================================
# Step 1: Install the inference engine
# ============================================================
echo "=== Installing the inference engine ==="
echo ""
emit_step_start "engine" "Installing the inference engine"
install_engine
emit_step_done "engine"

# ============================================================
# Step 2: Download and install models
# ============================================================
echo "=== Installing models ==="
echo ""
emit_step_start "models" "Installing models"

# Function to download and verify a model archive
download_and_verify() {
  archive="$1"
  expected_sha256="$2"
  archive_label="$3"

  echo "Downloading $archive..."
  download_with_retry "$BASE_URL/$archive" "$DOWNLOAD_DIR/$archive" "$archive_label"
  echo "  Download complete. Checking SHA256..."

  emit_activity "verifying" "$archive" "$archive_label"
  actual=$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{print $1}')
  if [ "$actual" != "$expected_sha256" ]; then
    echo "  ERROR: SHA256 mismatch for $archive"
    echo "    Expected: $expected_sha256"
    echo "    Actual:   $actual"
    emit_error "SHA256 mismatch for $archive"
    wait_and_exit 1
  fi
  echo "  SHA256 verified: $actual"
}

# Check if a model has been fully unzipped to the models directory.
# Each archive unpacks into $MODELS_DIR/<model_id>. A completion marker file is
# written after extraction — a model directory without it is a leftover from an
# interrupted extraction.
model_completion_marker() {
  echo "$MODELS_DIR/.$1.installed"
}

model_installed() {
  model_id="$1"
  [ -d "$MODELS_DIR/$model_id" ] && [ -f "$(model_completion_marker "$model_id")" ]
}

# Download and install each model only if not already present
install_model_if_needed() {
  zip_file="$1"
  sha256_sum="$2"
  model_id="$3"
  model_label="$4"

  if model_installed "$model_id"; then
    echo "  Model $model_id is already installed. Skipping."
    echo ""
    return 0
  fi

  echo "  Model $model_id is not installed. Proceeding..."
  echo ""
  download_and_verify "$zip_file" "$sha256_sum" "$model_label"
  echo "Extracting $zip_file to $MODELS_DIR..."
  emit_activity "extracting" "$zip_file" "$model_label"
  # Remove leftovers from a previously interrupted extraction — the path is
  # spelled out instead of using $MODELS_DIR so the rm -rf target is explicit
  rm -rf "$BASE_DIR/models/$model_id"
  if [ "$MACHINE_OUTPUT" = true ]; then
    extract_with_progress_events "$DOWNLOAD_DIR/$zip_file" "$MODELS_DIR/$model_id" "$model_label"
  else
    unzip -q "$DOWNLOAD_DIR/$zip_file" -d "$MODELS_DIR"
  fi
  touch "$(model_completion_marker "$model_id")"
  echo "  Extraction complete."
  echo ""
}

install_model_if_needed "$MODEL_ZIP_1" "$MODEL_SHA256_1" "$MODEL_ID_1" "$MODEL_LABEL_1"
install_model_if_needed "$MODEL_ZIP_2" "$MODEL_SHA256_2" "$MODEL_ID_2" "$MODEL_LABEL_2"

# Cleanup model downloads
echo "Removing downloaded archives..."
rm -rf "$DOWNLOAD_DIR"
emit_step_done "models"

# ============================================================
# Step 3: Configure Junie
# ============================================================
echo "=== Configuring Junie ==="
echo ""
emit_step_start "configure" "Configuring Junie"
# These degrade gracefully with warnings; without `|| true` a return 1
# would abort the script under `set -e`.
create_junie_model_config || true
set_default_junie_model || true
emit_step_done "configure"
echo ""

# ============================================================
# Step 4: Start the inference engine
# ============================================================
echo "=== Starting the inference engine ==="
echo ""
emit_step_start "start" "Starting the inference engine"
start_engine || true
emit_step_done "start"

if [ "$KEEP_CONFIG" = true ]; then
  echo ""
  echo "  Note: --keep-config is set, the previous server-config.json was preserved."
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Engine installed to: $ENGINE_DIR"
echo "  Current version:     $CURRENT_LINK -> $ENGINE_DIR"
echo "  Models installed to: $MODELS_DIR"
echo "  Engine log:          $ENGINE_DAEMON_LOG"
echo "  Junie model config:  $JUNIE_HOME/models/${JUNIE_MODEL_ID}.json"
echo ""
echo "  The engine serves http://localhost:$ENGINE_PORT — the first request has"
echo "  to wait for the model to load."
echo "  Default model set to $JUNIE_MODEL_ID."
echo "  Restart Junie to apply the changes."
echo "  Control the engine with: $ENGINE_CTL {start|stop|status|wait}"
emit_event "\"event\":\"done\",\"model_id\":\"$JUNIE_MODEL_ID\",\"port\":$ENGINE_PORT,\"model_path\":\"$(json_escape "$MODELS_DIR/$MODEL_ID_1")\",\"label\":\"$(json_escape "$MODEL_LABEL_1")\""
wait_and_exit 0
