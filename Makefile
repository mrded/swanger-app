# Everyday commands, matching what CI runs (.github/workflows/ci.yml). `make` lists them.

PROJECT := App/Swanger.xcodeproj
SCHEME := Swanger
DERIVED := build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
	-derivedDataPath $(DERIVED) -clonedSourcePackagesDirPath build/SourcePackages
FORMAT_PATHS := Package.swift Sources Tests App/Swanger
# The spec `make run` opens.
SPEC ?= Tests/SwangerValidationTests/Fixtures/payments/spec.yaml

.DEFAULT_GOAL := help
.PHONY: help check test lint format build run release xcode clean

help: ## List the commands
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-8s %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)

check: lint test build ## Lint, test and build the app, as CI does

test: ## Run the package tests (FILTER=Name runs only matching tests)
	swift test --parallel $(if $(FILTER),--filter '$(FILTER)')

lint: ## Check formatting
	xcrun swift-format lint --strict --recursive $(FORMAT_PATHS)

format: ## Fix formatting in place
	xcrun swift-format format --in-place --recursive $(FORMAT_PATHS)

build: ## Build the app (Debug)
	$(XCODEBUILD) -configuration Debug build -quiet

run: build ## Build and open the app (SPEC=path/to/spec.yaml)
	open -a "$(CURDIR)/$(DERIVED)/Build/Products/Debug/Swanger.app" "$(SPEC)"

release: ## Build a Release app, signed ad hoc, at build/Swanger.zip
	$(XCODEBUILD) -configuration Release build -quiet \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
	ditto -c -k --sequesterRsrc --keepParent $(DERIVED)/Build/Products/Release/Swanger.app \
		build/Swanger.zip
	@echo "build/Swanger.zip"

xcode: ## Open the project in Xcode
	open $(PROJECT)

clean: ## Remove build products (build/ and .build/)
	rm -rf build .build
