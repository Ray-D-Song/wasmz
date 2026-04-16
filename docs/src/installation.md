# Installation

## Install from Release

Install the latest published GitHub release directly into your user directory:

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/Ray-D-Song/wasmz/main/install.sh | bash
```

By default, this installs `wasmz` to `~/.local/bin`.

### Windows

```powershell
powershell -ExecutionPolicy Bypass -c "iwr https://raw.githubusercontent.com/Ray-D-Song/wasmz/main/install.ps1 -UseBasicParsing | iex"
```

By default, this installs `wasmz.exe` to `%LOCALAPPDATA%\wasmz\bin`.

You can also download the installer scripts and run them locally:

```bash
./install.sh --help
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

These scripts install the latest stable GitHub release by default, and also support installing a specific tag.

## Prerequisites

- **Zig 0.15.2** - Download from [ziglang.org](https://ziglang.org/download/)
- **Git** - For cloning the repository
- **make** - For build commands

## Build from Source

```bash
# Clone the repository
git clone https://github.com/anomalyco/wasmz.git
cd wasmz

# Build (ReleaseSafe - recommended for development)
make build

# Build for debugging
make build-debug

# Build for maximum performance
make release
```

The binary will be at `zig-out/bin/wasmz`.

## Build Options

| Command | Description |
|---------|-------------|
| `make build-debug` | Debug build (unoptimized, fast compile) |
| `make build` | ReleaseSafe build (optimized, safety checks) |
| `make release` | ReleaseFast build (maximum performance) |
| `make test` | Run all unit tests |
| `make clib` | Build C shared library |

## Build Mode Differences

The build mode affects panic handling in the CLI binary:

| Mode | Panic Handler | Binary Size | Backtrace |
|------|---------------|-------------|-----------|
| Debug | Full panic handler | Larger | ✅ Readable stack trace |
| ReleaseSafe | Full panic handler | Larger | ✅ Readable stack trace |
| ReleaseFast | Minimal panic handler | ~127 KB smaller | ❌ No backtrace |
| ReleaseSmall | Minimal panic handler | ~127 KB smaller | ❌ No backtrace |

**Recommendation**: Use `make build` (ReleaseSafe) for development - it provides optimizations while keeping safety checks and readable error messages. Use `make release` (ReleaseFast) for production deployments where binary size matters.

## Running Tests

```bash
# Run all unit tests
make test

# Run integration tests (requires building fixtures first)
zig build sqlite-wasm    # Build SQLite WASM fixture
zig build test-sqlite    # Run SQLite integration tests
```

## Installation

Install to `~/.local/bin`:

```bash
# Install debug build
make install

# Install release build
make install-release
```

After installation, ensure `~/.local/bin` is in your `PATH`.

## C Library

Build the C shared library for embedding:

```bash
make clib
```

Output files:
- `zig-out/lib/libwasmz.so` (Linux)
- `zig-out/lib/libwasmz.dylib` (macOS)
- `zig-out/lib/libwasmz.dll` (Windows)
- `zig-out/include/wasmz.h` (header)

## Verify Installation

```bash
# Check the CLI
wasmz --help

# Or run directly
./zig-out/bin/wasmz --help

# Run a simple test
echo '(module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))' > test.wat
wat2wasm test.wat
wasmz test.wasm add 1 2
# Output: 3
```
