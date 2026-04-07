BIN      := wasmz
INSTALL  := $(HOME)/.local/bin

.PHONY: build release install

build:
	zig build -Doptimize=ReleaseSafe
	@ls -lh zig-out/bin/$(BIN)

release:
	zig build -Doptimize=ReleaseFast
	@ls -lh zig-out/bin/$(BIN)

install: build
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"
