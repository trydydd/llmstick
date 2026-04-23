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
| `llama.cpp-<commit>-linux-x86_64-cpu.tar.gz` | varies | Project-managed rotorquant runtime release asset (`runtime-cpu/`) |
| `llama.cpp-<commit>-linux-x86_64-cuda.tar.gz` | varies | Project-managed rotorquant runtime release asset (`runtime-cuda/`) |
| `Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf` | ~4.0GB | [HuggingFace](https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/tree/main/Qwen3-4B-Instruct-2507-abliterated-GGUF) |
| `Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf` | ~2.3GB | [HuggingFace](https://huggingface.co/prithivMLmods/Qwen3-4B-2507-abliterated-GGUF/tree/main/Qwen3-4B-Instruct-2507-abliterated-GGUF) |

The builder defaults to project-managed release URLs, but you can override them with:

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
6. GPU is detected (NVIDIA on Linux) and the best runtime package is selected:
   - `runtime-cuda/` when a CUDA-capable NVIDIA stack is available
   - `runtime-cpu/` otherwise
7. A KV-cache profile is selected:
   - `auto` → `planar3/f16` on CUDA, `f16/f16` on CPU
   - `compatibility` → `f16/f16`
   - `memory-saver` → `planar3/f16` (or `iso3/f16` if `LLMSTICK_KV_ROTATION=iso3`)
   - `max-compression` → `planar3/planar3` (or `iso3/iso3`)
8. If the runtime rejects the requested cache profile, the launcher retries with `f16/f16`
9. Model loads into memory (10-60 seconds)
10. `>` prompt appears — start asking questions

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

- Runtime source is pinned to the rotorquant-enabled `johndpope/llama-cpp-turboquant` branch `feature/planarquant-kv-cache`, commit `20efe75`.
- `LinuxLaunch.sh` currently uses `llama-cli` for terminal chat and detects `llama-server` so the later orchestrator can reuse the same packaged runtime.
- Existing rotorquant-capable forks can be reused immediately by overriding the package URLs in `BuildYourOwn.sh`.

## Tech Stack

| Component | Technology | License |
|-----------|-----------|---------|
| AI Engine (Linux) | `llama.cpp` rotorquant runtime package | MIT |
| Model | [Qwen3-4B-Instruct abliterated](https://huggingface.co/prithivMLmods/Qwen3-4B-Instruct-2507-abliterated-GGUF) | Apache 2.0 |
| KV Profiles | `f16`, `planar3`, `iso3` (runtime-dependent) | — |
| Context Window | 8192 tokens (default) | — |

## Support

This is offered AS-IS, and you are responsible for your own support.
