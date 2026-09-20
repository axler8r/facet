SHELL := /usr/bin/env bash

NIX ?= nix develop -c
NIM ?= $(NIX) nim
BIN := filemeta

.PHONY: build test test-existing release clean

build:
	$(NIM) c -d:release -o:$(BIN) src/filemeta.nim

test: build
	$(MAKE) test-existing

test-existing:
	$(NIM) c -r --verbosity:0 tests/test_filemeta.nim $(TEST_ARGS)

release:
	$(NIM) c -d:release --opt:speed --passC:"-DSQLITE_THREADSAFE=1" --passC:"-DSQLITE_DEFAULT_FOREIGN_KEYS=1" --passC:"-DSQLITE_OMIT_LOAD_EXTENSION" -o:$(BIN) src/filemeta.nim

clean:
	rm -rf nimcache $(BIN) tests/test_filemeta
