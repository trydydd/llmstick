# LLM Stick

**Offline, uncensored, zero-log AI on a Linux flash drive.**

No internet. No installation. No accounts. Plug in, double-click, ask anything.

This project is derived from and inspired by the original [OSE FACTS project](https://github.com/WEAREOSE/facts), which served as the source, starting point, and inspiration for this work.

I've stripped Windows and Mac support to reduce scope for features that are in-flight. For those operating systems check the original project.

---

## What Is This?

This is the complete, open-source build for the **LLM Stick** AI flash drive. Everything you need to build your own is right here — the launcher scripts, the guide files, and the folder structure. 

## Quick Start

### Build Your Own

1. Get a USB flash drive (16GB minimum, 32GB+ recommended)
2. Format it as exFAT
3. Clone or download this repo onto the drive
4. Run the setup script:

   ```bash
   ./BuildYourOwn.sh --target /path/to/usb/mount
   ```

5. Or manually unpack the required runtime packages into the `.system/` folder (see below)
6. Run `LinuxLaunch.sh`

### Required Downloads (Not Included)

| File | Size | Source |
|------|------|--------|
| `llama-<release>-bin-ubuntu-<arch>.tar.gz` | varies | Pinned upstream `ggml-org/llama.cpp` release asset (`runtime-cpu/`) |
| `llama-<release>-bin-ubuntu-vulkan-<arch>.tar.gz` | varies | Pinned upstream accelerated Linux release asset (`runtime-cuda/`, Vulkan by default) |
| `Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf` | ~4.0GB | [HuggingFace](https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/tree/main/Qwen3-4B-Instruct-2507-abliterated-GGUF) |
| `Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf` | ~2.3GB | [HuggingFace](https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/tree/main/Qwen3-4B-Instruct-2507-abliterated-GGUF) |
| `Qwen3-4B-Thinking-2507-abliterated.Q8_0.gguf` | ~4.0GB | [HuggingFace](https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/tree/main/Qwen3-4B-Thinking-2507-abliterated-GGUF) |
| `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` | varies | [HuggingFace](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/tree/main) |

The builder defaults to pinned upstream `llama.cpp` release URLs, but you can override them with:

```bash
LLAMA_CPP_CPU_PACKAGE_URL=...
LLAMA_CPP_CUDA_PACKAGE_URL=...
./BuildYourOwn.sh --target /path/to/usb
```

That makes it easy to reuse existing llama.cpp forks or build repos that already publish rotorquant-capable binaries.

## Hardware Requirements

| | Minimum | Recommended |
|---|---------|-------------|
| **RAM** | 8GB | 16GB+ |
| **Linux** | Any modern x86_64 or ARM64 | NVIDIA GPU for acceleration |
| **Drive** | USB 2.0 works | USB 3.0 for faster load times |

## How It Works

1. Plug in the drive
2. Run `LinuxLaunch.sh`
3. The launcher kills any ghost processes from previous sessions
4. All chat history is wiped (zero-log privacy — nothing is ever saved)
5. Your RAM is detected and the best model is selected:
   - 16GB+ → Q8 (high quality)
   - 8-15GB → Q4 (efficiency mode)
   - `./LinuxLaunch.sh --thinking` or `LLMSTICK_MODEL_PROFILE=thinking ./LinuxLaunch.sh` → Thinking Q8 when installed, otherwise fall back to the normal auto-selected model
   - `./LinuxLaunch.sh --coder` or `LLMSTICK_MODEL_PROFILE=coder ./LinuxLaunch.sh` → Qwen3 Coder Q4_K_M when installed, otherwise fall back to the normal auto-selected model
6. GPU is detected (NVIDIA on Linux) and the best runtime package is selected:
   - `runtime-cuda/` when a CUDA-capable NVIDIA stack is available
   - `runtime-cpu/` otherwise
7. A KV-cache profile is selected:
   - `auto` (default) → equivalent to `memory-saver`; prefer rotorquant `turbo3/f16`; if the selected runtime does not advertise rotorquant cache types, use a supported quantized fallback instead
   - `compatibility` via `LLMSTICK_KV_PROFILE=compatibility ./LinuxLaunch.sh` → `f16/f16`
   - `memory-saver` via `LLMSTICK_KV_PROFILE=memory-saver ./LinuxLaunch.sh` → prefer `turbo3/f16` (or `planar3/f16` / `iso3/f16` when `LLMSTICK_KV_ROTATION` is overridden), otherwise use a supported quantized fallback
   - `max-compression` via `LLMSTICK_KV_PROFILE=max-compression ./LinuxLaunch.sh` → prefer `turbo3/turbo3` (or `planar3/planar3` / `iso3/iso3` when `LLMSTICK_KV_ROTATION` is overridden), otherwise use a supported quantized fallback
8. If the runtime still rejects the requested cache profile, the launcher retries with `f16/f16`
9. Model loads into memory (10-60 seconds)
10. `>` prompt appears — start asking questions

## LinuxLaunch.sh Flags and Overrides

```bash
./LinuxLaunch.sh --thinking
./LinuxLaunch.sh --coder

LLMSTICK_MODEL_PROFILE=auto|thinking|coder ./LinuxLaunch.sh
LLMSTICK_KV_PROFILE=auto|compatibility|memory-saver|max-compression ./LinuxLaunch.sh
LLMSTICK_KV_ROTATION=turbo3|planar3|iso3 ./LinuxLaunch.sh
LLMSTICK_CTX_SIZE=8192 ./LinuxLaunch.sh
```

- `--thinking` prefers `Qwen3-4B-Thinking-2507-abliterated.Q8_0.gguf`.
- `--coder` prefers `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`.
- `LLMSTICK_MODEL_PROFILE=thinking|coder` provides the same model overrides without adding CLI flags.
- `LLMSTICK_KV_PROFILE=compatibility` forces the safest `f16/f16` cache mode.
- `LLMSTICK_KV_PROFILE=memory-saver` prefers a mixed rotorquant profile (`turbo3/f16` by default).
- `LLMSTICK_KV_PROFILE=max-compression` prefers the smallest rotorquant profile (`turbo3/turbo3` by default).
- `LLMSTICK_KV_ROTATION` changes which rotorquant family `memory-saver` and `max-compression` try first.
- `LLMSTICK_CTX_SIZE` overrides the default 8192-token context window.
- If a requested Thinking or Coder model is missing, the launcher falls back to the normal RAM-based auto selection.

## What's In the Box

```
LLM Stick/
├── LinuxLaunch.sh              # Linux launcher
├── LICENSES/
│   ├── LLAMA_CPP_LICENSE.txt   # MIT License (llama.cpp)
│   └── MODEL LICENSES/
│       └── QWEN_LICENSE.txt    # Apache 2.0 (Qwen)
└── .system/                    # Hidden folder
   ├── runtime-cpu/             # CPU llama.cpp package (llama-cli + llama-server)
   ├── runtime-cuda/            # CUDA llama.cpp package (llama-cli + llama-server)
   ├── *.Q8_0.gguf              # High performance model (~4GB)
   ├── *Thinking*.Q8_0.gguf     # Optional Thinking model (~4GB)
   ├── *Coder*.Q4_K_M.gguf      # Optional Coder model
   └── *.Q4_K_M.gguf            # Efficiency model (~2.3GB)
```

## Troubleshooting

### Linux
| Problem | Fix |
|---------|-----|
| "Runtime not found" | Re-run `BuildYourOwn.sh` or unpack runtime tarballs into `.system/runtime-cpu` and `.system/runtime-cuda` |
| Hangs forever | Check `free -m` — need 4GB+ available. Close browsers. |
| Slow performance | Normal without NVIDIA GPU. CPU inference works but is slower. |
| KV profile rejected | Set `LLMSTICK_KV_PROFILE=compatibility` and retry |

- **AI crashes mid-conversation:** Context window full. Close and relaunch.
- **AI refuses to answer:** Close and relaunch. Rephrase the question.

## Runtime Notes

- Default runtime packages are pinned to `ggml-org/llama.cpp` release `b8893`.
- `runtime-cuda/` currently uses the pinned Linux Vulkan build as the default accelerated package; override `LLAMA_CPP_CUDA_PACKAGE_URL` if you have a CUDA-specific fork or release.
- Rotorquant reference source remains `johndpope/llama-cpp-turboquant` branch `feature/planarquant-kv-cache`, commit `20efe75`, for users who want to override the packaged runtime.
- `LinuxLaunch.sh` currently uses `llama-cli` for terminal chat and detects `llama-server` so the later orchestrator can reuse the same packaged runtime.
- `LinuxLaunch.sh --thinking` prefers `Qwen3-4B-Thinking-2507-abliterated.Q8_0.gguf` and falls back to the standard models if it is missing.
- `LinuxLaunch.sh --coder` prefers `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` and falls back to the standard models if it is missing.
- `LLMSTICK_MODEL_PROFILE`, `LLMSTICK_KV_PROFILE`, `LLMSTICK_KV_ROTATION`, and `LLMSTICK_CTX_SIZE` can all be used as environment-variable launch overrides.
- Existing rotorquant-capable forks can be reused immediately by overriding the package URLs in `BuildYourOwn.sh`.
- When the packaged runtime only supports standard llama.cpp cache types (for example `q8_0`), `LinuxLaunch.sh` now downgrades the requested rotorquant cache profile to a supported quantized cache mode before launch.

## Tech Stack

| Component | Technology | License |
|-----------|-----------|---------|
| AI Engine (Linux) | `llama.cpp` rotorquant runtime package | MIT |
| Model | [Qwen3-4B-Instruct abliterated](https://huggingface.co/prithivMLmods/Qwen3-4B-Instruct-2507-abliterated-GGUF) | Apache 2.0 |
| KV Profiles | `f16`, `turbo3`, `planar3`, `iso3` (runtime-dependent) | — |
| Context Window | 8192 tokens (default) | — |

## Support

This is offered AS-IS, and you are responsible for your own support.
