# MEMORY

## What We Changed

### 1) Added automated USB builder script
- Created `BuildYourOwn.sh` to automate the README build process.
- It can:
  - copy repo files to a mounted USB target
  - create `.system/`
  - download required engine + model files
  - optionally format the drive as exFAT

### 2) Added `formatme` marker behavior
- Script now checks for `TARGET/formatme`.
- If present, formatting runs without an interactive confirmation prompt.
- If `--format-device` is not provided, the script attempts to auto-detect the device from the mount path.

### 3) Added local model reuse
- Before downloading model files, script checks:
  1. `~/Download`
  2. `~/Downloads`
- If models are found locally, they are copied into `.system/` instead of downloading.

### 4) Split engine downloads by platform compatibility
- The runtime now targets rotorquant-enabled `llama.cpp` packages instead of `llamafile`.
- `BuildYourOwn.sh` downloads and extracts two Linux runtime packages:
  - `.system/runtime-cpu`
  - `.system/runtime-cuda`
- Package URLs are overrideable so existing rotorquant-capable llama.cpp forks can be reused when they publish binaries.

### 5) Improved Linux launcher diagnostics
- Updated `LinuxLaunch.sh` to provide more actionable error output.
- Added a post-failure probe that reveals unsupported model architecture errors (for example, `qwen3`) that were previously hidden by `--log-disable`.
- Launcher now detects CPU vs CUDA runtime packages, reports the active runtime, and falls back to CPU when the CUDA package is unavailable or unusable.
- Launcher exposes KV-cache profiles (`compatibility`, `memory-saver`, `max-compression`) and retries with `f16/f16` if a rotorquant profile is rejected by the runtime.

### 6) Added user setup documentation
- Added `USB_SETUP_README.md` with terminal-first instructions for:
  - finding USB mount path/device on Linux
  - running `BuildYourOwn.sh` with correct `--target` syntax
  - optional formatting
  - `formatme` mode
  - common mistakes

### 7) Reduced scope to Linux-only
- Removed `MacLaunch.command` and `WindowsLaunch.bat`.
- Refactored `BuildYourOwn.sh` to download only Linux runtime packages and to run only on Linux.
- Removed Mac/Windows references from docs and setup instructions.

### 8) Pinned rotorquant runtime source
- Default runtime expectations are pinned to `johndpope/llama-cpp-turboquant`
- Branch: `feature/planarquant-kv-cache`
- Commit: `20efe75`

## Why
- The initial launcher error was too generic and made root-cause diagnosis difficult.
- Runtime testing showed model load failures tied to engine/model architecture compatibility.
- Users needed a repeatable, low-friction terminal workflow to identify their USB and run setup safely.
- Local model reuse reduces repeated multi-GB downloads and setup time.
- Reducing the current implementation to Linux-only cuts platform-specific complexity while the orchestrator architecture is still being defined.
- Moving to `llama.cpp` packages avoids depending on llamafile packaging when the project already ships separate engine and model assets.
- Existing rotorquant-capable forks may save build time, so the runtime download URLs are configurable rather than hard-wired to one source forever.
