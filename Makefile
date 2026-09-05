APP     = ".build/Headroom AI.app"
DIST    = .build/dist
DMG     = ".build/Headroom AI.dmg"

# Release signing. The team id is part of the certificate's name, so it is not
# a secret; the certificate itself lives in the login keychain.
TEAM_ID = A7TM5GYDM3
SIGN_ID = Developer ID Application: Mariusz Tarnaski ($(TEAM_ID))

# Credentials for notarytool, stored once with:
#   xcrun notarytool store-credentials headroom-notary \
#     --apple-id <your Apple ID> --team-id $(TEAM_ID) --password <app-specific password>
# App-specific passwords come from appleid.apple.com, not your Apple ID password.
NOTARY_PROFILE ?= headroom-notary

.PHONY: app run test clean bundle sign dmg notarize release

test:
	swift test

# Ad-hoc signed: fine on this machine, refused as "unidentified developer"
# anywhere else. That is what `release` is for.
app: bundle
	codesign --force --sign - $(APP)
	@echo "Built $(APP) (ad-hoc signed, this machine only)"

bundle:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/Headroom $(APP)/Contents/MacOS/Headroom

# Hardened runtime and a secure timestamp are both required before Apple will
# notarize anything.
sign: bundle
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	@echo "Signed with Developer ID"

dmg: sign
	rm -rf $(DIST) $(DMG)
	mkdir -p $(DIST)
	cp -R $(APP) $(DIST)/
	ln -s /Applications $(DIST)/Applications
	hdiutil create -volname "Headroom AI" -srcfolder $(DIST) -ov -format UDZO $(DMG)

# Stapling matters: without it the first launch needs a working network
# connection for Gatekeeper to check the notarisation.
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -v $(DMG)
	@echo "Notarised and stapled: $(DMG)"

release: notarize

run: app
	open $(APP)

clean:
	rm -rf .build
