# ScreenMate — developer entry points.
#
# `make test` runs the platform-independent core suite anywhere a Swift toolchain
# exists. `make test-all` additionally runs the macOS suite and only works on a Mac.

.PHONY: help build app test test-all lint clean

help:
	@echo "make build     — compile the package"
	@echo "make app       — build dist/ScreenMate.app (macOS only)"
	@echo "make test      — run the ScreenMateCore suite"
	@echo "make test-all  — run every suite (macOS only)"
	@echo "make clean     — remove build products"

build:
	swift build

app:
	./Scripts/build-app.sh release

test:
	swift test --filter ScreenMateCoreTests

test-all:
	swift test

clean:
	swift package clean
	rm -rf .build dist
