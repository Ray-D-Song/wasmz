BIN      := wasmz
INSTALL  := $(HOME)/.local/bin

.PHONY: build release install

build:
	zig build -Doptimize=ReleaseSafe

release:
	zig build -Doptimize=ReleaseFast

install: build
	mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "Installed $(INSTALL)/$(BIN)"
