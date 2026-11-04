VERSION := $(shell cat VERSION)
IDENTIFIER := com.kastruppro.brewau
BUILD := build
ROOT := $(BUILD)/root

# Override on the command line, e.g.
#   make release INSTALLER_IDENTITY="Developer ID Installer: Jane Doe (TEAMID)"
INSTALLER_IDENTITY ?= Developer ID Installer: Tobias Jul Kastrup (5W98EXLE44)
NOTARY_PROFILE ?= kastruppro-notary
# Checkout of github.com/kastruppro/homebrew-tap, updated by `make tap`.
TAP_DIR ?= ../homebrew-tap
APPLICATION_IDENTITY ?= Developer ID Application: Tobias Jul Kastrup (5W98EXLE44)
CODESIGN_IDENTITY ?= -
CODESIGN_TIMESTAMP ?= --timestamp=none

UNSIGNED_PKG := $(BUILD)/brewau-$(VERSION)-unsigned.pkg
SIGNED_PKG := $(BUILD)/brewau-$(VERSION).pkg

.PHONY: all stage pkg sign notarize release tap test lint install uninstall clean mockup mockup-check mockup-previews app agent app-check

all: pkg

app:
	mkdir -p "$(BUILD)/brewau.app/Contents/MacOS" "$(BUILD)/brewau.app/Contents/Resources"
	xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$(BUILD)/swift-module-cache" \
		app/Core.swift app/AppModel.swift app/Views.swift app/BrewauApp.swift -o "$(BUILD)/brewau.app/Contents/MacOS/brewau"
	sed "s/__VERSION__/$(VERSION)/g" app/Info.plist > "$(BUILD)/brewau.app/Contents/Info.plist"
	xcrun swift -module-cache-path "$(BUILD)/swift-module-cache" app/Icon.swift "$(BUILD)/AppIcon.iconset"
	iconutil -c icns "$(BUILD)/AppIcon.iconset" -o "$(BUILD)/brewau.app/Contents/Resources/AppIcon.icns"
	codesign --force --options runtime $(CODESIGN_TIMESTAMP) --sign "$(CODESIGN_IDENTITY)" "$(BUILD)/brewau.app"

agent:
	mkdir -p $(BUILD)
	xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$(BUILD)/swift-module-cache" \
		app/Core.swift app/Completions.swift app/Agent.swift -o "$(BUILD)/brewau-agent"
	codesign --force --options runtime $(CODESIGN_TIMESTAMP) --sign "$(CODESIGN_IDENTITY)" "$(BUILD)/brewau-agent"

app-check:
	mkdir -p $(BUILD)
	xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$(BUILD)/swift-module-cache" \
		app/Core.swift app/Completions.swift app/Tests.swift -o "$(BUILD)/app-tests"
	"$(BUILD)/app-tests"

# Standalone design prototype; deliberately excluded from the installer.
mockup:
	mkdir -p "$(BUILD)/brewau Mockup.app/Contents/MacOS"
	xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$(BUILD)/swift-module-cache" \
		mockup/BrewauMockup.swift -o "$(BUILD)/brewau Mockup.app/Contents/MacOS/brewau-mockup"
	cp mockup/Info.plist "$(BUILD)/brewau Mockup.app/Contents/Info.plist"
	codesign --force --sign - "$(BUILD)/brewau Mockup.app"

mockup-check: mockup
	"$(BUILD)/brewau Mockup.app/Contents/MacOS/brewau-mockup" --self-check

mockup-previews: mockup
	"$(BUILD)/brewau Mockup.app/Contents/MacOS/brewau-mockup" --render mockup/previews

stage: app agent
	rm -rf $(ROOT)
	mkdir -p $(ROOT)
	ditto payload $(ROOT)
	ditto "$(BUILD)/brewau.app" "$(ROOT)/Applications/brewau.app"
	cp "$(BUILD)/brewau-agent" "$(ROOT)/opt/brewau/libexec/brewau-agent"
	echo "$(VERSION)" > $(ROOT)/opt/brewau/share/VERSION
	find $(ROOT) -type d -exec chmod 0755 {} +
	find $(ROOT) -type f -exec chmod 0644 {} +
	chmod 0755 $(ROOT)/opt/brewau/bin/* $(ROOT)/opt/brewau/libexec/brew-policy \
		$(ROOT)/opt/brewau/libexec/brewau-upgrade $(ROOT)/opt/brewau/libexec/brewau-setup \
		$(ROOT)/opt/brewau/libexec/brewau-services $(ROOT)/opt/brewau/libexec/brewau-agent \
		"$(ROOT)/Applications/brewau.app/Contents/MacOS/brewau"
	chmod 0755 scripts/preinstall scripts/postinstall

pkg: stage
	pkgbuild --root $(ROOT) --scripts scripts --identifier $(IDENTIFIER) \
		--component-plist app/components.plist \
		--version $(VERSION) --install-location / --ownership recommended \
		$(BUILD)/brewau-component.pkg
	sed "s/__VERSION__/$(VERSION)/" distribution.xml > $(BUILD)/distribution.xml
	productbuild --distribution $(BUILD)/distribution.xml --package-path $(BUILD) \
		--version $(VERSION) $(UNSIGNED_PKG)
	@echo "Built $(UNSIGNED_PKG)"

sign: CODESIGN_IDENTITY = $(APPLICATION_IDENTITY)
sign: CODESIGN_TIMESTAMP = --timestamp
sign: pkg
	productsign --sign "$(INSTALLER_IDENTITY)" --timestamp $(UNSIGNED_PKG) $(SIGNED_PKG)
	pkgutil --check-signature $(SIGNED_PKG)

notarize: sign
	xcrun notarytool submit $(SIGNED_PKG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(SIGNED_PKG)
	spctl --assess --type install --verbose $(SIGNED_PKG)

# install.sh downloads releases/latest/download/brewau.pkg, so upload that name.
release: notarize
	cp $(SIGNED_PKG) $(BUILD)/brewau.pkg
	@echo "Release ready: upload $(SIGNED_PKG) and $(BUILD)/brewau.pkg to GitHub release v$(VERSION)"

# Points the tap's brewau cask at this release; push the tap after the upload.
tap: release
	scripts/update-tap $(SIGNED_PKG) $(VERSION) $(TAP_DIR)

test:
	@set -e; for t in tests/*_test.sh; do echo "$$t"; /bin/bash "$$t"; done

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck not found; install it with: brew install shellcheck" >&2; exit 1; }
	shellcheck -x -S warning payload/opt/brewau/bin/* payload/opt/brewau/libexec/* scripts/* install.sh tests/*.sh

# Install from this checkout without building a package.
install: stage
	sudo ./install.sh --from $(ROOT)

uninstall:
	sudo /opt/brewau/libexec/brewau-setup uninstall

clean:
	rm -rf $(BUILD)
