# Everyday commands, matching what CI runs (.github/workflows/ci.yml). `make` lists them.

PROJECT := App/Swanger.xcodeproj
SCHEME := Swanger
DERIVED := build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
	-derivedDataPath $(DERIVED) -clonedSourcePackagesDirPath build/SourcePackages
FORMAT_PATHS := Package.swift Sources Tests App/Swanger App/SwangerUITests
# The spec `make run` opens.
SPEC ?= Tests/SwangerValidationTests/Fixtures/payments/spec.yaml

.DEFAULT_GOAL := help
.PHONY: help check test real-world ui-test lint format build run release site xcode clean

help: ## List the commands
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-8s %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)

check: lint test build ## Lint, test and build the app, as CI does

test: ## Run the package tests (FILTER=Name runs only matching tests)
	swift test --parallel $(if $(FILTER),--filter '$(FILTER)')

real-world: ## Download GitHub's spec and run the real-world spec tests on it too
	scripts/fetch-real-world-specs.sh
	swift test --filter RealWorldSpecTests

lint: ## Check formatting
	xcrun swift-format lint --strict --recursive $(FORMAT_PATHS)

format: ## Fix formatting in place
	xcrun swift-format format --in-place --recursive $(FORMAT_PATHS)

build: ## Build the app (Debug)
	$(XCODEBUILD) -configuration Debug build -quiet

ui-test: ## Run the app's UI smoke tests (needs automation mode, see CONTRIBUTING.md)
	$(XCODEBUILD) test

run: build ## Build and open the app (SPEC=path/to/spec.yaml)
	open -a "$(CURDIR)/$(DERIVED)/Build/Products/Debug/Swanger.app" "$(SPEC)"

release: ## Build a Release app, signed ad hoc, at build/Swanger.zip
	$(XCODEBUILD) -configuration Release build -quiet \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
	ditto -c -k --sequesterRsrc --keepParent $(DERIVED)/Build/Products/Release/Swanger.app \
		build/Swanger.zip
	@echo "build/Swanger.zip"

site: ## Assemble the website at build/site, with the README's screenshots
	rm -rf build/site
	mkdir -p build/site/screenshots
	cp -R site/. build/site/
	cp docs/screenshots/*.png build/site/screenshots/
	@echo "build/site (preview: python3 -m http.server -d build/site)"

xcode: ## Open the project in Xcode
	open $(PROJECT)

clean: ## Remove build products (build/ and .build/)
	rm -rf build .build
