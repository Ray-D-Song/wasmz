BIN      := wasmz
INSTALL  := $(HOME)/.local/bin

.PHONY:  build-debug build release install install-release

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