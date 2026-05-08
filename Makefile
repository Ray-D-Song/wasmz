BIN      := wasmz
INSTALL  := $(HOME)/.local/bin

.PHONY: build-debug build release install install-debug install-release uninstall test clib bench build-wasi build-wasm

build-debug:
	zig build -Doptimize=Debug -Dprofiling=true
	@ls -lh zig-out/bin/$(BIN)

build:
	zig build -Doptimize=ReleaseSafe -Dprofiling=true
	@ls -lh zig-out/bin/$(BIN)

release:
	zig build -Doptimize=ReleaseFast
	@ls -lh zig-out/bin/$(BIN)

install-debug: build-debug
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"

install: build
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"

install-release: release
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"

uninstall:
	rm -f $(INSTALL)/$(BIN)
	@echo "Removed $(INSTALL)/$(BIN)"

test:
	zig build test
	@echo "All unit tests passed."

clib:
	zig build clib
	@ls -lh zig-out/lib/libwasmz.* 2>/dev/null || ls -lh zig-out/lib/
	@ls -lh zig-out/include/wasmz.h

bench:
	./bench/bench.sh

count-ops:
	$(MAKE) install-debug
	./tests/profiling-qjs-fib.sh

build-wasi:
	zig build wasi
	@ls -lh zig-out/wasi/wasmz.wasm

build-wasm:
	zig build wasm
	@ls -lh zig-out/wasm/wasmz.wasm
