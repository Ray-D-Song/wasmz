BIN      := wasmz
INSTALL  := $(HOME)/.local/bin

.PHONY: build-debug build release install install-release test clib

build-debug:
	zig build -Doptimize=Debug
	@ls -lh zig-out/bin/$(BIN)

build:
	zig build -Doptimize=ReleaseSafe
	@ls -lh zig-out/bin/$(BIN)

release:
	zig build -Doptimize=ReleaseFast
	@ls -lh zig-out/bin/$(BIN)

install: build-debug
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"

install-release: release
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"

test:
	zig build test
	@echo "All unit tests passed."

clib:
	zig build clib
	@ls -lh zig-out/lib/libwasmz.* 2>/dev/null || ls -lh zig-out/lib/
	@ls -lh zig-out/include/wasmz.h
