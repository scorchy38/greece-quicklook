APP := build/dd/Build/Products/Debug/Greece.app
SCHEME ?= Greece

.PHONY: all build test render install clean help
.DEFAULT_GOAL := build

all: build test ## Build and test everything

build: ## Build the app and extensions (Debug)
	xcodegen generate
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath build/dd build

test: build ## Run the GreeceKit test suite
	xcodebuild -scheme $(SCHEME) -derivedDataPath build/dd test

## Render every fixture to PNG, light and dark
render: build
	scripts/render.sh $(APP) /tmp/greece Fixtures/*/*

install: build ## Copy to /Applications and register with Quick Look
	scripts/install.sh

dist/Greece.dmg: build
	scripts/release.sh

clean: ## Remove build products
	rm -rf build dist

help:
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST)

%.png: %.svg
	rsvg-convert $< > $@
