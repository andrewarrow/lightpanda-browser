# Variables
# ---------

REQUIRED_ZIG_VERSION := $(shell sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)
REQUIRED_ZIG_SERIES := $(shell printf '%s\n' '$(REQUIRED_ZIG_VERSION)' | cut -d. -f1,2)
HOMEBREW_ZIG := $(shell if command -v brew >/dev/null 2>&1; then prefix=$$(brew --prefix zig@$(REQUIRED_ZIG_SERIES) 2>/dev/null); if [ -x "$$prefix/bin/zig" ]; then printf '%s/bin/zig' "$$prefix"; fi; fi)
ZIG ?= $(if $(HOMEBREW_ZIG),$(HOMEBREW_ZIG),zig)
BC := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# option test filter make test F="server"
F=
BUILD_HEARTBEAT_SECONDS ?= 30

# OS and ARCH
kernel = $(shell uname -ms)
ifeq ($(kernel), Darwin arm64)
	OS := macos
	ARCH := aarch64
else ifeq ($(kernel), Darwin x86_64)
	OS := macos
	ARCH := x86_64
else ifeq ($(kernel), Linux aarch64)
	OS := linux
	ARCH := aarch64
else ifeq ($(kernel), Linux arm64)
	OS := linux
	ARCH := aarch64
else ifeq ($(kernel), Linux x86_64)
	OS := linux
	ARCH := x86_64
else
	$(error "Unhandled kernel: $(kernel)")
endif

ifeq ($(OS), macos)
# V8 hooks invoke `python3` directly. Prefer Apple's Python on macOS so a
# broken Homebrew Python does not derail depot_tools during `gclient sync`.
export PATH := /usr/bin:/bin:/usr/sbin:/sbin:$(PATH)
endif

define run_with_heartbeat
	@start=$$(date +%s); \
	( \
		while true; do \
			sleep $(BUILD_HEARTBEAT_SECONDS); \
			now=$$(date +%s); \
			elapsed=$$((now - start)); \
			printf "\033[36mStill building (%ss elapsed)...\033[0m\n" "$$elapsed"; \
		done \
	) & heartbeat_pid=$$!; \
	trap 'kill "$$heartbeat_pid" 2>/dev/null || true; exit 130' INT; \
	trap 'kill "$$heartbeat_pid" 2>/dev/null || true; exit 143' TERM; \
	trap 'kill "$$heartbeat_pid" 2>/dev/null || true' EXIT; \
	$(1); status=$$?; \
	kill "$$heartbeat_pid" 2>/dev/null || true; \
	wait "$$heartbeat_pid" 2>/dev/null || true; \
	trap - INT TERM EXIT; \
	if [ $$status -ne 0 ]; then \
		printf "\033[33mBuild ERROR\033[0m\n"; \
		exit $$status; \
	fi
endef


# Infos
# -----
.PHONY: help

## Display this help screen
help:
	@printf "\033[36m%-35s %s\033[0m\n" "Command" "Usage"
	@sed -n -e '/^## /{'\
		-e 's/## //g;'\
		-e 'h;'\
		-e 'n;'\
		-e 's/:.*//g;'\
		-e 'G;'\
		-e 's/\n/ /g;'\
		-e 'p;}' Makefile | awk '{printf "\033[33m%-35s\033[0m%s\n", $$1, substr($$0,length($$1)+1)}'


# $(ZIG) commands
# ------------
.PHONY: check-zig-version build build-v8-snapshot build-dev run run-release test bench data end2end

check-zig-version:
	@version="$$( $(ZIG) version 2>/dev/null || true )"; \
	if [ "$$version" != "$(REQUIRED_ZIG_VERSION)" ]; then \
		printf "\033[33mZig $(REQUIRED_ZIG_VERSION) is required; found %s using $(ZIG).\033[0m\n" "$${version:-not found}"; \
		printf "Install the matching Zig version or run: make ZIG=/path/to/zig run\n"; \
		exit 1; \
	fi

## Build v8 snapshot
build-v8-snapshot: check-zig-version
	@printf "\033[36mBuilding v8 snapshot (release safe)...\033[0m\n"
	$(call run_with_heartbeat,$(ZIG) build -Doptimize=ReleaseFast snapshot_creator -- src/snapshot.bin)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in release-fast mode
build: build-v8-snapshot
	@printf "\033[36mBuilding (release fast)...\033[0m\n"
	$(call run_with_heartbeat,$(ZIG) build -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in debug mode
build-dev: check-zig-version
	@printf "\033[36mBuilding (debug)...\033[0m\n"
	$(call run_with_heartbeat,$(ZIG) build)
	@printf "\033[33mBuild OK\033[0m\n"

## Run the server in release mode
run: build
	@printf "\033[36mRunning...\033[0m\n"
	@./zig-out/bin/lightpanda || (printf "\033[33mRun ERROR\033[0m\n"; exit 1;)

## Run the server in debug mode
run-debug: build-dev
	@printf "\033[36mRunning...\033[0m\n"
	@./zig-out/bin/lightpanda || (printf "\033[33mRun ERROR\033[0m\n"; exit 1;)

## Test - `grep` is used to filter out the huge compile command on build
ifeq ($(OS), macos)
test: check-zig-version
	@script -q /dev/null sh -c 'TEST_FILTER="${F}" $(ZIG) build test -freference-trace' 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
else
test: check-zig-version
	@script -qec 'TEST_FILTER="${F}" $(ZIG) build test -freference-trace' /dev/null 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
endif

## Run demo/runner end to end tests
end2end:
	@test -d ../demo
	cd ../demo && go run runner/main.go

# Install and build required dependencies commands
# ------------
.PHONY: install

install: build

data:
	cd src/data && go run public_suffix_list_gen.go > public_suffix_list.zig
