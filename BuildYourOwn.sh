#!/usr/bin/env bash
set -euo pipefail

# Build a bootstrapped facts USB drive from this repository.
# - Copies repo files to target USB path
# - Creates .system/
# - Downloads required runtime packages/models
# - Optionally formats the device as exFAT (destructive)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET=""
TARGET_DIR="${DEFAULT_TARGET}"
FORMAT_DEVICE=""
USB_LABEL="facts"
SKIP_COPY="false"
SKIP_DOWNLOADS="false"
FORCE="false"
AUTO_FORMAT="false"

LLAMA_CPP_RUNTIME_VERSION="${LLAMA_CPP_RUNTIME_VERSION:-v0.1.0-rotorquant}"
ROTORQUANT_LLAMA_CPP_BRANCH="${ROTORQUANT_LLAMA_CPP_BRANCH:-feature/planarquant-kv-cache}"
ROTORQUANT_LLAMA_CPP_COMMIT="${ROTORQUANT_LLAMA_CPP_COMMIT:-20efe75}"
LLAMA_CPP_CPU_PACKAGE_URL="${LLAMA_CPP_CPU_PACKAGE_URL:-https://github.com/trydydd/llmstick/releases/download/${LLAMA_CPP_RUNTIME_VERSION}/llama.cpp-${ROTORQUANT_LLAMA_CPP_COMMIT}-linux-x86_64-cpu.tar.gz}"
LLAMA_CPP_CUDA_PACKAGE_URL="${LLAMA_CPP_CUDA_PACKAGE_URL:-https://github.com/trydydd/llmstick/releases/download/${LLAMA_CPP_RUNTIME_VERSION}/llama.cpp-${ROTORQUANT_LLAMA_CPP_COMMIT}-linux-x86_64-cuda.tar.gz}"
Q8_URL="${Q8_URL:-https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/resolve/main/Qwen3-4B-Instruct-2507-abliterated-GGUF/Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf}"
Q4_URL="${Q4_URL:-https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/resolve/main/Qwen3-4B-Instruct-2507-abliterated-GGUF/Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf}"

usage() {
  cat <<'EOF'
Usage:
  ./BuildYourOwn.sh --target /path/to/usb [options]

Required:
  --target PATH              Mounted USB path (example: /media/$USER/facts)

Options:
  --format-device DEVICE     Format device as exFAT first (DESTRUCTIVE)
                             Linux example: /dev/sdb1
                             If TARGET/formatme exists, formatting runs without prompt
  --label NAME               exFAT volume label when formatting (default: facts)
  --skip-copy                Skip copying repo files to USB
  --skip-downloads           Skip all downloads
  --force                    Do not ask for confirmation on destructive steps
  -h, --help                 Show this help

Environment overrides:
  LLAMA_CPP_RUNTIME_VERSION
  LLAMA_CPP_CPU_PACKAGE_URL
  LLAMA_CPP_CUDA_PACKAGE_URL
  ROTORQUANT_LLAMA_CPP_BRANCH
  ROTORQUANT_LLAMA_CPP_COMMIT
  Q8_URL
  Q4_URL

Examples:
  ./BuildYourOwn.sh --target /media/$USER/facts
  ./BuildYourOwn.sh --target /media/$USER/facts --format-device /dev/sdb1 --force
EOF
}

log() {
  printf '[facts-builder] %s\n' "$*"
}

fail() {
  printf '[facts-builder] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

confirm() {
  local prompt="$1"
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

detect_device_from_target() {
  require_cmd findmnt
  findmnt -no SOURCE --target "$TARGET_DIR" 2>/dev/null || true
}

configure_format_from_marker() {
  local marker_file="$TARGET_DIR/formatme"
  [[ -f "$marker_file" ]] || return 0

  AUTO_FORMAT="true"
  log "Detected format marker: $marker_file"

  if [[ -z "$FORMAT_DEVICE" ]]; then
    FORMAT_DEVICE="$(detect_device_from_target)"
    [[ -n "$FORMAT_DEVICE" ]] || fail "Found formatme but could not detect device. Provide --format-device explicitly."
    log "Auto-detected format device: $FORMAT_DEVICE"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        TARGET_DIR="${2:-}"
        shift 2
        ;;
      --format-device)
        FORMAT_DEVICE="${2:-}"
        shift 2
        ;;
      --label)
        USB_LABEL="${2:-facts}"
        shift 2
        ;;
      --skip-copy)
        SKIP_COPY="true"
        shift
        ;;
      --skip-downloads)
        SKIP_DOWNLOADS="true"
        shift
        ;;
      --force)
        FORCE="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$TARGET_DIR" ]] || fail "--target is required"
}

format_exfat_if_requested() {
  [[ -n "$FORMAT_DEVICE" ]] || return 0

  log "Formatting requested: $FORMAT_DEVICE as exFAT"

  if [[ "$AUTO_FORMAT" == "true" ]]; then
    log "Skipping confirmation because formatme marker is present"
  else
    if ! confirm "Formatting will erase all data on $FORMAT_DEVICE. Continue?"; then
      fail "Aborted by user"
    fi
  fi

  require_cmd mkfs.exfat
  require_cmd mountpoint
  if mountpoint -q "$TARGET_DIR"; then
    log "Unmounting current target mount: $TARGET_DIR"
    sudo umount "$TARGET_DIR" || true
  fi
  log "Creating exFAT filesystem on $FORMAT_DEVICE"
  sudo mkfs.exfat -n "$USB_LABEL" "$FORMAT_DEVICE"
  mkdir -p "$TARGET_DIR"
  log "Mounting $FORMAT_DEVICE to $TARGET_DIR"
  sudo mount "$FORMAT_DEVICE" "$TARGET_DIR"
}

copy_repo_to_usb() {
  [[ "$SKIP_COPY" == "false" ]] || {
    log "Skipping repo copy (--skip-copy)"
    return 0
  }

  require_cmd rsync
  mkdir -p "$TARGET_DIR"

  log "Copying repository files to USB target"
  rsync -a --exclude '.git' --exclude '.DS_Store' "$SCRIPT_DIR/" "$TARGET_DIR/"
}

download_file() {
  local url="$1"
  local output="$2"
  local size_hint="$3"

  require_cmd curl
  mkdir -p "$(dirname -- "$output")"

  # Re-runs should not redownload large artifacts if they already exist.
  if [[ -s "$output" ]]; then
    log "Using existing file: $(basename -- "$output")"
    return 0
  fi

  log "Downloading $(basename -- "$output") ${size_hint}"
  # -C - resumes partial downloads; important for multi-GB model files.
  curl -fL --progress-bar -C - "$url" -o "$output"
}

copy_from_local_downloads_if_present() {
  local filename="$1"
  local output="$2"
  local primary_dir="$HOME/Download"
  local fallback_dir="$HOME/Downloads"
  local candidate=""

  if [[ -s "$output" ]]; then
    log "Using existing model file: $(basename -- "$output")"
    return 0
  fi

  if [[ -f "$primary_dir/$filename" ]]; then
    candidate="$primary_dir/$filename"
  elif [[ -f "$fallback_dir/$filename" ]]; then
    candidate="$fallback_dir/$filename"
  else
    return 1
  fi

  mkdir -p "$(dirname -- "$output")"
  log "Using local model file: $candidate"
  cp -f "$candidate" "$output"
  return 0
}

download_or_copy_local_asset() {
  local url="$1"
  local output="$2"
  local size_hint="$3"
  local filename

  filename="$(basename -- "$url")"

  if ! copy_from_local_downloads_if_present "$filename" "$output"; then
    download_file "$url" "$output" "$size_hint"
  fi
}

extract_tarball() {
  local archive="$1"
  local destination="$2"

  require_cmd tar
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination"
}

install_runtime_package() {
  local label="$1"
  local url="$2"
  local destination="$3"
  local archive
  local archive_name

  archive_name="$(basename -- "$url")"
  archive="$TMPDIR/$archive_name"

  log "Preparing runtime package: $label"
  download_or_copy_local_asset "$url" "$archive" "(runtime package)"
  extract_tarball "$archive" "$destination"
}

download_required_assets() {
  [[ "$SKIP_DOWNLOADS" == "false" ]] || {
    log "Skipping downloads (--skip-downloads)"
    return 0
  }

  local system_dir="$TARGET_DIR/.system"
  mkdir -p "$system_dir"
  log "Checking local assets in $HOME/Download (preferred), then $HOME/Downloads"

  install_runtime_package "CPU runtime" "$LLAMA_CPP_CPU_PACKAGE_URL" "$system_dir/runtime-cpu"
  install_runtime_package "CUDA runtime" "$LLAMA_CPP_CUDA_PACKAGE_URL" "$system_dir/runtime-cuda"
  find "$system_dir/runtime-cpu" "$system_dir/runtime-cuda" -type f \( -name 'llama-cli' -o -name 'llama-server' \) -exec chmod +x {} + 2>/dev/null || true

  download_or_copy_local_asset \
    "$Q8_URL" \
    "$system_dir/Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf" \
    "(~4.0GB)"

  download_or_copy_local_asset \
    "$Q4_URL" \
    "$system_dir/Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf" \
    "(~2.3GB)"

}

print_summary() {
  cat <<EOF

Build complete.

Target: $TARGET_DIR
Created/updated: $TARGET_DIR/.system/

Installed files:
- runtime-cpu/ (llama.cpp CLI + server package)
- runtime-cuda/ (llama.cpp CLI + server package)
- Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf
- Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf

Pinned rotorquant source:
- repo: johndpope/llama-cpp-turboquant
- branch: $ROTORQUANT_LLAMA_CPP_BRANCH
- commit: $ROTORQUANT_LLAMA_CPP_COMMIT

Next step:
- Eject the USB drive safely, plug into target Linux machine, run LinuxLaunch.sh.
EOF
}

main() {
  TMPDIR="$(mktemp -d -t llmstick-build.XXXXXX)"
  trap 'rm -rf "$TMPDIR"' EXIT

  parse_args "$@"

  require_cmd uname
  [[ "$(uname -s)" == "Linux" ]] || fail "This builder is Linux-only"
  [[ -d "$SCRIPT_DIR" ]] || fail "Unable to resolve script directory"

  configure_format_from_marker

  format_exfat_if_requested

  [[ -d "$TARGET_DIR" ]] || mkdir -p "$TARGET_DIR"

  copy_repo_to_usb
  download_required_assets
  print_summary
}

main "$@"
