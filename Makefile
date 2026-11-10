# Build, test and install MenuBarHider. `make gen` needs xcodegen (brew install xcodegen).
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

SCHEME    := MenuBarHider
BUILD_DIR := build
APP       := $(BUILD_DIR)/Build/Products/Release/MenuBarHider.app

# Signing overrides (see project.yml). Put your defaults into local.mk, which is git-ignored:
#   SIGN_IDENTITY := Developer ID Application
#   TEAM          := XXXXXXXXXX
-include local.mk
# Source builds default to ad-hoc signing; release builds need a Developer ID.
ifeq ($(origin SIGN_IDENTITY), undefined)
SIGN_IDENTITY := -
RELEASE_SIGN_IDENTITY ?= Developer ID Application
else
RELEASE_SIGN_IDENTITY ?= $(SIGN_IDENTITY)
endif
TEAM          ?=
SIGN_FLAGS    := CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(TEAM)"

XCODEBUILD := xcodebuild -project MenuBarHider.xcodeproj -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR)

.PHONY: gen build test run install lint release clean

gen:
	xcodegen generate --use-cache

build: gen
	$(XCODEBUILD) -configuration Release $(SIGN_FLAGS) build | tail -5

test: gen
	$(XCODEBUILD) -configuration Debug test 2>&1 | grep -E 'Test Case|error|passed|failed|Executed' | tail -30

lint:
	swiftlint lint --quiet
	xcrun swift-format lint --recursive --configuration .swift-format MenuBarHider MenuBarHiderTests

run: build
	@if pgrep -x MenuBarHider >/dev/null; then \
		echo "Quit MenuBarHider from its menu before running a different build." >&2; \
		exit 1; \
	fi
	open $(APP)

install: build
	scripts/install.sh "$(APP)"

release:
	SIGN_IDENTITY="$(RELEASE_SIGN_IDENTITY)" TEAM="$(TEAM)" scripts/release.sh

clean:
	rm -rf $(BUILD_DIR) dist MenuBarHider.xcodeproj
