BIN      := wasmz
INSTALL  := $(HOME)/.local/bin

.PHONY: build-debug build release install install-debug install-release test clib bench

build-debug:
	zig build -Doptimize=Debug -Dprofiling=true
	@ls -lh zig-out/bin/$(BIN)

build:
	zig build -Doptimize=ReleaseSafe
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

test:
	zig build test
	@echo "All unit tests passed."

clib:
	zig build clib
	@ls -lh zig-out/lib/libwasmz.* 2>/dev/null || ls -lh zig-out/lib/
	@ls -lh zig-out/include/wasmz.h

bench:
	$(MAKE) install-release
	./bench/bench.sh

count-ops:
	$(MAKE) install-debug
	./tests/profiling-qjs-fib.sh
