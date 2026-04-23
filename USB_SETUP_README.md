# USB Setup Guide (Terminal)

This guide shows how to:
- find your USB drive in terminal
- get the correct mount path for `--target`
- run `BuildYourOwn.sh` safely

## 1) Open a terminal in this repo

```bash
cd /path/to/llmstick
```

Make sure the script is executable:

```bash
chmod +x BuildYourOwn.sh
```

## 2) Find your USB drive

### Linux

Plug in the USB, then run:

```bash
df -h | grep -E '/media|/run/media|/mnt'
```

This shows likely USB mount points first.

Then run:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL,TRAN
```

Use this to identify the device node (often `TRAN` = `usb`).

Typical results:
- Device: `/dev/sdb1`
- Mount path: `/media/<your-user>/facts` or `/run/media/<your-user>/facts`

## 3) Run the builder script

### Basic run (no formatting)

Use your USB mount path for `--target`:

```bash
./BuildYourOwn.sh --target /path/to/usb/mount
```

Examples:

```bash
./BuildYourOwn.sh --target /media/$USER/facts
```

## 4) Optional: format as exFAT from script

Formatting erases the drive.

### Explicit format (recommended when unsure)

Linux example:

```bash
./BuildYourOwn.sh --target /media/$USER/facts --format-device /dev/sdb1
```

### `formatme` marker mode (no prompt)

If a file named `formatme` exists at the USB root, the script skips the format confirmation prompt.

```bash
touch /path/to/usb/mount/formatme
./BuildYourOwn.sh --target /path/to/usb/mount
```

Notes:
- Marker mode is destructive when formatting is triggered.
- If needed, you can still pass `--format-device` explicitly.

## 5) Local asset shortcut

Before downloading runtime packages and model files, the script checks:
1. `~/Download`
2. `~/Downloads`

If it finds:
- the runtime package archives named by `LLAMA_CPP_CPU_PACKAGE_URL` / `LLAMA_CPP_CUDA_PACKAGE_URL`
- `Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf`
- `Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf`

it reuses them instead of downloading again.

Runtime package tarballs are extracted into:

- `.system/runtime-cpu`
- `.system/runtime-cuda`

You can point the builder at an existing rotorquant-enabled fork release:

```bash
LLAMA_CPP_CPU_PACKAGE_URL=https://example.com/llama.cpp-rotorquant-cpu.tar.gz \
LLAMA_CPP_CUDA_PACKAGE_URL=https://example.com/llama.cpp-rotorquant-cuda.tar.gz \
./BuildYourOwn.sh --target /path/to/usb/mount
```

## 6) Common mistake

This is incorrect:

```bash
./BuildYourOwn.sh /sda
```

The script requires a named argument:

```bash
./BuildYourOwn.sh --target /path/to/usb/mount
```

## 7) Help

```bash
./BuildYourOwn.sh --help
```

## 8) Launcher profile overrides

The Linux launcher accepts optional overrides:

```bash
LLMSTICK_KV_PROFILE=compatibility|memory-saver|max-compression|auto
LLMSTICK_KV_ROTATION=planar3|iso3
LLMSTICK_CTX_SIZE=8192
./LinuxLaunch.sh
```

## Scope

This repository is Linux-only.
