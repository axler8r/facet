SHELL := /usr/bin/env bash

NIX ?= nix develop -c
NIM ?= $(NIX) nim
BIN := facet

.PHONY: build test test-existing release clean

build:
	$(NIM) c -d:release -o:$(BIN) src/facet.nim

test: build
	$(MAKE) test-existing

test-existing:
	$(NIM) c -r --verbosity:0 tests/test_facet.nim $(TEST_ARGS)

release:
	$(NIM) c -d:release --opt:speed --passC:"-DSQLITE_THREADSAFE=1" --passC:"-DSQLITE_DEFAULT_FOREIGN_KEYS=1" --passC:"-DSQLITE_OMIT_LOAD_EXTENSION" -o:$(BIN) src/facet.nim

clean:
	rm -rf nimcache $(BIN) tests/test_facet
