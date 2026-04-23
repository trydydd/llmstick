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

LLAMA_CPP_RUNTIME_REPO="${LLAMA_CPP_RUNTIME_REPO:-ggml-org/llama.cpp}"
LLAMA_CPP_RUNTIME_VERSION="${LLAMA_CPP_RUNTIME_VERSION:-b8893}"
ROTORQUANT_LLAMA_CPP_REPO="${ROTORQUANT_LLAMA_CPP_REPO:-johndpope/llama-cpp-turboquant}"
ROTORQUANT_LLAMA_CPP_BRANCH="${ROTORQUANT_LLAMA_CPP_BRANCH:-feature/planarquant-kv-cache}"
ROTORQUANT_LLAMA_CPP_COMMIT="${ROTORQUANT_LLAMA_CPP_COMMIT:-20efe75}"
# Set to "false" to skip the source build and download a pre-built runtime instead.
ROTORQUANT_BUILD_RUNTIME="${ROTORQUANT_BUILD_RUNTIME:-true}"
LLAMA_CPP_RUNTIME_ARCH="${LLAMA_CPP_RUNTIME_ARCH:-$(uname -m 2>/dev/null || printf 'unknown')}"

case "$LLAMA_CPP_RUNTIME_ARCH" in
  x86_64|amd64)
    LLAMA_CPP_RUNTIME_PLATFORM="${LLAMA_CPP_RUNTIME_PLATFORM:-x64}"
    ;;
  aarch64|arm64)
    LLAMA_CPP_RUNTIME_PLATFORM="${LLAMA_CPP_RUNTIME_PLATFORM:-arm64}"
    ;;
  *)
    LLAMA_CPP_RUNTIME_PLATFORM="${LLAMA_CPP_RUNTIME_PLATFORM:-}"
    ;;
esac

LLAMA_CPP_CPU_PACKAGE_URL="${LLAMA_CPP_CPU_PACKAGE_URL:-}"
if [[ -z "$LLAMA_CPP_CPU_PACKAGE_URL" && -n "$LLAMA_CPP_RUNTIME_PLATFORM" ]]; then
  LLAMA_CPP_CPU_PACKAGE_URL="https://github.com/${LLAMA_CPP_RUNTIME_REPO}/releases/download/${LLAMA_CPP_RUNTIME_VERSION}/llama-${LLAMA_CPP_RUNTIME_VERSION}-bin-ubuntu-${LLAMA_CPP_RUNTIME_PLATFORM}.tar.gz"
fi

LLAMA_CPP_CUDA_PACKAGE_URL="${LLAMA_CPP_CUDA_PACKAGE_URL:-}"
if [[ -z "$LLAMA_CPP_CUDA_PACKAGE_URL" && -n "$LLAMA_CPP_RUNTIME_PLATFORM" ]]; then
  LLAMA_CPP_CUDA_PACKAGE_URL="https://github.com/${LLAMA_CPP_RUNTIME_REPO}/releases/download/${LLAMA_CPP_RUNTIME_VERSION}/llama-${LLAMA_CPP_RUNTIME_VERSION}-bin-ubuntu-vulkan-${LLAMA_CPP_RUNTIME_PLATFORM}.tar.gz"
fi
Q8_URL="${Q8_URL:-https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/resolve/main/Qwen3-4B-Instruct-2507-abliterated-GGUF/Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf}"
Q4_URL="${Q4_URL:-https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/resolve/main/Qwen3-4B-Instruct-2507-abliterated-GGUF/Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf}"
THINKING_Q8_URL="${THINKING_Q8_URL:-https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/resolve/main/Qwen3-4B-Thinking-2507-abliterated-GGUF/Qwen3-4B-Thinking-2507-abliterated.Q8_0.gguf?download=true}"
CODER_Q4_URL="${CODER_Q4_URL:-https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf?download=true}"

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
  LLAMA_CPP_RUNTIME_REPO
  LLAMA_CPP_RUNTIME_VERSION
  LLAMA_CPP_RUNTIME_ARCH
  LLAMA_CPP_RUNTIME_PLATFORM
  LLAMA_CPP_CPU_PACKAGE_URL
  LLAMA_CPP_CUDA_PACKAGE_URL
  ROTORQUANT_LLAMA_CPP_REPO
  ROTORQUANT_LLAMA_CPP_BRANCH
  ROTORQUANT_LLAMA_CPP_COMMIT
  ROTORQUANT_BUILD_RUNTIME    Set to "false" to skip source build and use pre-built runtime
  Q8_URL
  Q4_URL
  THINKING_Q8_URL
  CODER_Q4_URL

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

check_build_deps_available() {
  local missing=()
  for dep in git cmake make gcc g++; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  if (( ${#missing[@]} > 0 )); then
    log "Missing build tools: ${missing[*]}"
    return 1
  fi
  return 0
}

build_rotorquant_runtime() {
  local destination="$1"
  shift
  local -a extra_cmake_args=("$@")
  local src_dir="$TMPDIR/rotorquant-src"
  local build_dir="$TMPDIR/rotorquant-build"
  local stamp_file="$destination/.rotorquant-build-commit"

  # Skip if already built at the same commit.
  if [[ -f "$stamp_file" ]] && [[ "$(cat "$stamp_file" 2>/dev/null)" == "$ROTORQUANT_LLAMA_CPP_COMMIT" ]]; then
    if [[ -x "$destination/bin/llama-cli" ]]; then
      log "Rotorquant runtime already built at commit $ROTORQUANT_LLAMA_CPP_COMMIT, skipping rebuild"
      return 0
    fi
  fi

  if [[ ! -d "$src_dir/.git" ]]; then
    log "Cloning $ROTORQUANT_LLAMA_CPP_REPO (branch: $ROTORQUANT_LLAMA_CPP_BRANCH)"
    git clone --depth 50 \
      --branch "$ROTORQUANT_LLAMA_CPP_BRANCH" \
      "https://github.com/$ROTORQUANT_LLAMA_CPP_REPO.git" \
      "$src_dir" || return 1
  fi

  log "Checking out pinned commit: $ROTORQUANT_LLAMA_CPP_COMMIT"
  git -C "$src_dir" checkout "$ROTORQUANT_LLAMA_CPP_COMMIT" || return 1

  mkdir -p "$build_dir"

  log "Configuring rotorquant llama.cpp build..."
  cmake \
    -B "$build_dir" \
    -S "$src_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DCMAKE_INSTALL_PREFIX="$destination" \
    "${extra_cmake_args[@]}" || return 1

  local nproc_count
  nproc_count="$(nproc 2>/dev/null || echo 2)"
  log "Compiling llama.cpp (using $nproc_count jobs — this may take several minutes)..."
  cmake --build "$build_dir" --config Release -j"$nproc_count" || return 1

  log "Installing rotorquant runtime to $destination..."
  cmake --install "$build_dir" || return 1

  printf '%s\n' "$ROTORQUANT_LLAMA_CPP_COMMIT" > "$stamp_file"
  return 0
}

install_rotorquant_cpu_runtime() {
  local destination="$1"

  if [[ "$ROTORQUANT_BUILD_RUNTIME" != "true" ]]; then
    log "ROTORQUANT_BUILD_RUNTIME=false: using pre-built package instead of source build"
    [[ -n "$LLAMA_CPP_CPU_PACKAGE_URL" ]] || fail "No default CPU runtime package URL. Set LLAMA_CPP_CPU_PACKAGE_URL explicitly."
    install_runtime_package "CPU runtime" "$LLAMA_CPP_CPU_PACKAGE_URL" "$destination"
    return
  fi

  if ! check_build_deps_available; then
    log "Build tools unavailable — falling back to pre-built CPU package"
    [[ -n "$LLAMA_CPP_CPU_PACKAGE_URL" ]] || fail "No default CPU runtime package URL. Set LLAMA_CPP_CPU_PACKAGE_URL explicitly."
    install_runtime_package "CPU runtime" "$LLAMA_CPP_CPU_PACKAGE_URL" "$destination"
    return
  fi

  log "Building rotorquant-compatible llama.cpp from source (CPU)"
  if build_rotorquant_runtime "$destination"; then
    log "Rotorquant CPU runtime built and installed successfully"
  else
    log "Rotorquant source build failed — falling back to pre-built CPU package"
    [[ -n "$LLAMA_CPP_CPU_PACKAGE_URL" ]] || fail "No default CPU runtime package URL. Set LLAMA_CPP_CPU_PACKAGE_URL explicitly."
    install_runtime_package "CPU runtime" "$LLAMA_CPP_CPU_PACKAGE_URL" "$destination"
  fi
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
  local attempts=5
  local attempt=1
  local retry_delay

  require_cmd curl
  mkdir -p "$(dirname -- "$output")"

  # Re-runs should not redownload large artifacts if they already exist.
  if [[ -s "$output" ]]; then
    log "Using existing file: $(basename -- "$output")"
    return 0
  fi

  log "Downloading $(basename -- "$output") ${size_hint}"
  # -C - resumes partial downloads; important for multi-GB model files.
  while (( attempt <= attempts )); do
    if curl -fL --progress-bar -C - "$url" -o "$output"; then
      return 0
    fi

    if (( attempt == attempts )); then
      fail "Download failed after $attempts attempts: $(basename -- "$output")"
    fi

    log "Retrying download ($(basename -- "$output"), attempt $((attempt + 1))/$attempts)"
    retry_delay=$((2 ** attempt))
    (( retry_delay > 16 )) && retry_delay=16
    sleep "$retry_delay"
    ((attempt++))
  done
}

copy_from_local_downloads_if_present() {
  local filename="$1"
  local output="$2"
  local primary_dir="$HOME/Download"
  local fallback_dir="$HOME/Downloads"
  local candidate=""

  if [[ -s "$output" ]]; then
    log "Using existing asset: $(basename -- "$output")"
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
  log "Using local asset: $candidate"
  cp -f "$candidate" "$output"
  return 0
}

download_or_copy_local_asset() {
  local url="$1"
  local output="$2"
  local size_hint="$3"
  local output_filename
  local url_basename

  output_filename="$(basename -- "$output")"
  url_basename="$(basename -- "${url%%\?*}")"

  if copy_from_local_downloads_if_present "$url_basename" "$output"; then
    return 0
  fi

  # Some asset URLs add query strings or use a different URL-path basename than
  # the final pinned on-disk filename, so check both local naming conventions.
  if [[ "$output_filename" != "$url_basename" ]] && copy_from_local_downloads_if_present "$output_filename" "$output"; then
    return 0
  fi

  download_file "$url" "$output" "$size_hint"
}

extract_tarball() {
  local archive="$1"
  local destination="$2"
  local staging_dir=""
  local temp_root=""
  local tar_entry=""
  local tar_part=""
  local tar_listing=""
  local tar_type=""
  local tar_link_path=""
  local tar_link_target=""
  local link_parent=""
  local canonical_link_target=""
  local rsync_error_log=""
  local rsync_error_message=""
  local canonical_root=""
  local canonical_destination=""
  local extracted_path=""
  local canonical_extracted_path=""
  local copy_source=""
  local wrapper_dir=""
  local wrapper_name=""
  local -a top_level_entries=()
  local -a tar_parts=()

  require_cmd tar
  require_cmd realpath
  require_cmd rsync
  [[ -n "$destination" ]] || fail "Refusing to extract archive to an empty destination"
  [[ "$destination" != "/" ]] || fail "Refusing to extract archive to /"
  canonical_root="$(realpath -m "$TARGET_DIR/.system")"
  canonical_destination="$(realpath -m "$destination")"
  [[ "$canonical_destination" == "$canonical_root/"* ]] || fail "Refusing to extract archive outside $canonical_root: $destination"

  validate_archive_path() {
    local path="$1"
    [[ -n "$path" ]] || fail "Unsafe archive path in $(basename -- "$archive"): empty path"
    [[ "$path" == /* ]] && fail "Unsafe archive path in $(basename -- "$archive"): $path"
    IFS='/' read -r -a tar_parts <<< "$path"
    for tar_part in "${tar_parts[@]}"; do
      [[ "$tar_part" == ".." ]] && fail "Unsafe archive path in $(basename -- "$archive"): $path"
    done
    return 0
  }

  while IFS= read -r tar_listing; do
    tar_type="${tar_listing%% *}"
    tar_type="${tar_type:0:1}"
    if [[ "$tar_type" == "l" ]]; then
      tar_link_path="$(sed -E 's/^([^[:space:]]+[[:space:]]+){5}//' <<<"$tar_listing")"
      [[ "$tar_link_path" == *" -> "* ]] || fail "Unsafe archive entry in $(basename -- "$archive"): malformed symbolic link"
      tar_link_target="${tar_link_path#* -> }"
      tar_link_path="${tar_link_path% -> *}"
      validate_archive_path "$tar_link_path"
      [[ -n "$tar_link_target" ]] || fail "Unsafe archive entry in $(basename -- "$archive"): malformed symbolic link"
      [[ "$tar_link_target" == /* ]] && fail "Unsafe archive entry in $(basename -- "$archive"): absolute symbolic links are not allowed"
      validate_archive_path "$tar_link_target"
      link_parent="$(dirname -- "$tar_link_path")"
      canonical_link_target="$(realpath -m "$canonical_destination/$link_parent/$tar_link_target")"
      [[ "$canonical_link_target" == "$canonical_destination/"* ]] || fail "Unsafe archive entry in $(basename -- "$archive"): symbolic link escapes destination"
    elif [[ "$tar_type" == "h" ]]; then
      fail "Unsafe archive entry in $(basename -- "$archive"): hard links are not allowed"
    fi
  done < <(tar -tvzf "$archive")

  while IFS= read -r tar_entry; do
    validate_archive_path "$tar_entry"
  done < <(tar -tzf "$archive")

  temp_root="${TMPDIR:-/tmp}"
  staging_dir="$(mktemp -d "$temp_root/extract.XXXXXX")"
  tar -xzf "$archive" -C "$staging_dir"

  while IFS= read -r extracted_path; do
    [[ -L "$extracted_path" && ! -e "$extracted_path" ]] && fail "Unsafe archive entry in $(basename -- "$archive"): broken symbolic link: ${extracted_path#"$staging_dir"/}"
    canonical_extracted_path="$(realpath -m "$extracted_path")"
    [[ "$canonical_extracted_path" == "$staging_dir" || "$canonical_extracted_path" == "$staging_dir/"* ]] || fail "Unsafe extracted path from $(basename -- "$archive"): $extracted_path"
  done < <(find "$staging_dir" -mindepth 1 -print)

  copy_source="$staging_dir"
  mapfile -t top_level_entries < <(find "$staging_dir" -mindepth 1 -maxdepth 1 -print)
  if (( ${#top_level_entries[@]} == 1 )) && [[ -d "${top_level_entries[0]}" ]]; then
    wrapper_dir="${top_level_entries[0]}"
    wrapper_name="$(basename -- "$wrapper_dir")"
    if [[ "$wrapper_name" == "llama-"* ]]; then
      copy_source="$wrapper_dir"
    fi
  fi

  rm -rf "$destination"
  mkdir -p "$destination"
  rsync_error_log="$(mktemp "$temp_root/rsync.XXXXXX")"
  if ! rsync -aL "$copy_source"/ "$destination"/ 2>"$rsync_error_log"; then
    rsync_error_message="$(head -n 1 "$rsync_error_log" | tr '\r\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    rm -f "$rsync_error_log"
    rm -rf "$staging_dir"
    fail "Failed to copy runtime from staging directory to $destination${rsync_error_message:+: $rsync_error_message}"
  fi
  rm -f "$rsync_error_log"

  while IFS= read -r extracted_path; do
    canonical_extracted_path="$(realpath -m "$extracted_path")"
    [[ "$canonical_extracted_path" == "$canonical_destination" || "$canonical_extracted_path" == "$canonical_destination/"* ]] || fail "Unsafe extracted path from $(basename -- "$archive"): $extracted_path"
  done < <(find "$destination" -mindepth 1 -print)

  if [[ -n "$(find "$destination" -type l -print -quit)" ]]; then
    rm -rf "$staging_dir"
    fail "Unexpected symbolic links found after copy operation: $destination"
  fi

  rm -rf "$staging_dir"
  return 0
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

  [[ -n "$LLAMA_CPP_CPU_PACKAGE_URL" ]] || fail "No default CPU runtime package is defined for architecture '$LLAMA_CPP_RUNTIME_ARCH'. Set LLAMA_CPP_CPU_PACKAGE_URL explicitly."
  install_rotorquant_cpu_runtime "$system_dir/runtime-cpu"

  if [[ -n "$LLAMA_CPP_CUDA_PACKAGE_URL" ]]; then
    install_runtime_package "CUDA runtime" "$LLAMA_CPP_CUDA_PACKAGE_URL" "$system_dir/runtime-cuda"
  else
    log "Skipping accelerated runtime package because no default package is defined for architecture '$LLAMA_CPP_RUNTIME_ARCH'"
  fi

  if [[ -d "$system_dir/runtime-cpu" ]]; then
    find "$system_dir/runtime-cpu" -type f \( -name 'llama-cli' -o -name 'llama-server' \) -exec chmod +x {} +
  fi

  if [[ -d "$system_dir/runtime-cuda" ]]; then
    find "$system_dir/runtime-cuda" -type f \( -name 'llama-cli' -o -name 'llama-server' \) -exec chmod +x {} +
  fi

  download_or_copy_local_asset \
    "$Q8_URL" \
    "$system_dir/Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf" \
    "(~4.0GB)"

  download_or_copy_local_asset \
    "$Q4_URL" \
    "$system_dir/Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf" \
    "(~2.3GB)"

  download_or_copy_local_asset \
    "$THINKING_Q8_URL" \
    "$system_dir/Qwen3-4B-Thinking-2507-abliterated.Q8_0.gguf" \
    "(~4.0GB)"

  download_or_copy_local_asset \
    "$CODER_Q4_URL" \
    "$system_dir/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" \
    "(~17GB)"

}

print_summary() {
  local accelerated_summary="(not installed)"
  local cpu_runtime_summary="llama.cpp CLI + server (pre-built package)"
  if [[ "$ROTORQUANT_BUILD_RUNTIME" == "true" ]] && [[ -f "$TARGET_DIR/.system/runtime-cpu/.rotorquant-build-commit" ]]; then
    cpu_runtime_summary="llama.cpp CLI + server (rotorquant build from source)"
  fi
  if [[ -d "$TARGET_DIR/.system/runtime-cuda" ]]; then
    accelerated_summary="runtime-cuda/ (accelerated Linux llama.cpp package)"
  fi

  cat <<EOF

Build complete.

Target: $TARGET_DIR
Created/updated: $TARGET_DIR/.system/

Installed files:
- runtime-cpu/ ($cpu_runtime_summary)
- $accelerated_summary
- Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf
- Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf
- Qwen3-4B-Thinking-2507-abliterated.Q8_0.gguf
- Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

Rotorquant runtime source:
- repo: $ROTORQUANT_LLAMA_CPP_REPO
- branch: $ROTORQUANT_LLAMA_CPP_BRANCH
- commit: $ROTORQUANT_LLAMA_CPP_COMMIT
- build from source: $ROTORQUANT_BUILD_RUNTIME

Pre-built fallback package source:
- repo: $LLAMA_CPP_RUNTIME_REPO
- release: $LLAMA_CPP_RUNTIME_VERSION
- platform: ${LLAMA_CPP_RUNTIME_PLATFORM:-override-required}

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
