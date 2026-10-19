VERSION := $(shell cat VERSION)
IDENTIFIER := com.kastruppro.brewau
BUILD := build
ROOT := $(BUILD)/root

# Override on the command line, e.g.
#   make release INSTALLER_IDENTITY="Developer ID Installer: Jane Doe (TEAMID)"
INSTALLER_IDENTITY ?= Developer ID Installer: Tobias Jul Kastrup (5W98EXLE44)
NOTARY_PROFILE ?= kastruppro-notary

UNSIGNED_PKG := $(BUILD)/brewau-$(VERSION)-unsigned.pkg
SIGNED_PKG := $(BUILD)/brewau-$(VERSION).pkg

.PHONY: all stage pkg sign notarize release test lint install uninstall clean

all: pkg

stage:
	rm -rf $(ROOT)
	mkdir -p $(ROOT)
	ditto payload $(ROOT)
	echo "$(VERSION)" > $(ROOT)/opt/brewau/share/VERSION
	find $(ROOT) -type d -exec chmod 0755 {} +
	find $(ROOT) -type f -exec chmod 0644 {} +
	chmod 0755 $(ROOT)/opt/brewau/bin/* $(ROOT)/opt/brewau/libexec/brew-policy \
		$(ROOT)/opt/brewau/libexec/brewau-upgrade $(ROOT)/opt/brewau/libexec/brewau-setup
	chmod 0755 scripts/preinstall scripts/postinstall

pkg: stage
	pkgbuild --root $(ROOT) --scripts scripts --identifier $(IDENTIFIER) \
		--version $(VERSION) --install-location / --ownership recommended \
		$(BUILD)/brewau-component.pkg
	sed "s/__VERSION__/$(VERSION)/" distribution.xml > $(BUILD)/distribution.xml
	productbuild --distribution $(BUILD)/distribution.xml --package-path $(BUILD) \
		--version $(VERSION) $(UNSIGNED_PKG)
	@echo "Built $(UNSIGNED_PKG)"

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
	@echo "Release ready: $(BUILD)/brewau.pkg (upload as a GitHub release asset)"

test:
	./tests/policy_test.sh

lint:
	shellcheck -x payload/opt/brewau/bin/* payload/opt/brewau/libexec/* scripts/* install.sh tests/*.sh

# Install from this checkout without building a package.
install: stage
	sudo ./install.sh --from $(ROOT)

uninstall:
	sudo /opt/brewau/libexec/brewau-setup uninstall

clean:
	rm -rf $(BUILD)
