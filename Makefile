bin = rmtrash
install_dir = /opt/homebrew/bin
version = $(shell git describe --tags --abbrev=0)

.PHONY: deps
deps:
	swift package update

.PHONY: run
run:
	swift run

.PHONY: test
test:
	swift test

.PHONY: build
build:
	swift build -c release
	# install config in brew formula 
	# bin.install ".build/release/rmtrash"

.PHONY: manual
manual:
	swift package generate-manual
	# The plugin documents an implicit 'help' subcommand that rmtrash does not
	# actually have (it is a single command); strip that section.
	sed -e '/^\.Ar subcommand$$/d' -e '/^\.It Em help$$/,/^\.El$$/d' \
		.build/plugins/GenerateManual/outputs/$(bin)/$(bin).1 > Manual/$(bin).1
	# install config in brew formula
	# man1.install "Manual/rmtrash.1"

.PHONY: build-universal
build-universal:
	swift build --configuration release --arch x86_64
	swift build --configuration release --arch arm64
	lipo -create .build/x86_64-apple-macosx/release/$(bin) .build/arm64-apple-macosx/release/$(bin) -output .build/release/$(bin)

.PHONY: release
release: test build-universal manual
	mkdir -p .dist
	# x86_64
	cp Manual/$(bin).1 .build/x86_64-apple-macosx/release
	tar -czf .dist/$(bin)_$(version)_x86_64.tar.gz -C .build/x86_64-apple-macosx/release $(bin) $(bin).1
	# arm64
	cp Manual/$(bin).1 .build/arm64-apple-macosx/release
	tar -czf .dist/$(bin)_$(version)_arm64.tar.gz -C .build/arm64-apple-macosx/release $(bin) $(bin).1
	# universal
	cp Manual/$(bin).1 .build/release
	tar -czf .dist/$(bin)_$(version)_universal.tar.gz -C .build/release $(bin) $(bin).1

.PHONY: install
install: build
	mv .build/release/$(bin) $(install_dir)/$(bin)
	chmod +x $(install_dir)/$(bin)

.PHONY: style
style:
	swiftlint --autocorrect Sources/*
	swiftlint --autocorrect Tests/*
	swiftlint --autocorrect Package.swift

.PHONY: clean
clean:
	rm -rf .build .dist
