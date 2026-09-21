SHELL := /usr/bin/env bash

NIX ?= nix develop -c
NIM ?= $(NIX) nim
DIST_DIR := dist
BIN := $(DIST_DIR)/facet
TEST_BIN := $(DIST_DIR)/test_facet

.PHONY: init build test test-existing release format clean

init:
	@if [ ! -f .envrc ]; then \
		cp .envrc.example .envrc; \
		echo "Created .envrc from .envrc.example"; \
	else \
		echo ".envrc already exists"; \
	fi
	@if command -v direnv >/dev/null 2>&1; then \
		direnv allow; \
		echo "direnv enabled for this project"; \
	else \
		echo "direnv not found; install direnv or run commands via: nix develop -c <command>"; \
	fi

build:
	mkdir -p $(DIST_DIR)
	$(NIM) c -d:release -o:$(BIN) src/facet.nim

test: build
	$(MAKE) test-existing

test-existing:
	mkdir -p $(DIST_DIR)
	$(NIM) c -r --verbosity:0 -o:$(TEST_BIN) tests/test_facet.nim $(TEST_ARGS)

release:
	mkdir -p $(DIST_DIR)
	$(NIM) c -d:release --opt:speed --passC:"-DSQLITE_THREADSAFE=1" --passC:"-DSQLITE_DEFAULT_FOREIGN_KEYS=1" --passC:"-DSQLITE_OMIT_LOAD_EXTENSION" -o:$(BIN) src/facet.nim

format:
	$(NIX) nimpretty src/facet.nim src/facet/*.nim tests/test_facet.nim

clean:
	rm -rf nimcache $(DIST_DIR)
