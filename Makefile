# The DMG's name carries no space on purpose: GitHub rewrites spaces in release
# asset names, and the download link on tarnaski.pl points at a fixed filename.
APP     = ".build/Headroom AI.app"
DIST    = .build/dist
DMG     = .build/Headroom-AI.dmg
ZIP     = .build/Headroom-AI.zip

# Release signing. The team id is part of the certificate's name, so it is not
# a secret; the certificate itself lives in the login keychain.
TEAM_ID = A7TM5GYDM3
SIGN_ID = Developer ID Application: Mariusz Tarnaski ($(TEAM_ID))

# Credentials for notarytool, stored once with:
#   xcrun notarytool store-credentials headroom-notary \
#     --apple-id <your Apple ID> --team-id $(TEAM_ID) --password <app-specific password>
# App-specific passwords come from appleid.apple.com, not your Apple ID password.
NOTARY_PROFILE ?= headroom-notary

.PHONY: app run test clean bundle sign staple dmg notarize release

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

# The app gets a notarisation ticket of its own, stapled into the bundle. The
# DMG is notarised separately further down; only the app's own ticket survives
# being dragged out of the disk image, and it is what lets a first launch work
# without a network connection.
staple: sign
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP)
	rm -f $(ZIP)

# ditto rather than cp, because the ticket stapler just wrote is an extended
# attribute; validate proves it survived the copy.
dmg: staple
	rm -rf $(DIST) $(DMG)
	mkdir -p $(DIST)
	ditto $(APP) "$(DIST)/Headroom AI.app"
	xcrun stapler validate "$(DIST)/Headroom AI.app"
	ln -s /Applications $(DIST)/Applications
	hdiutil create -volname "Headroom AI" -srcfolder $(DIST) -ov -format UDZO $(DMG)
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)

# An unsigned disk image has nothing for spctl to assess, however well notarised
# its contents are — hence the codesign above before this ticket is fetched.
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -v $(DMG)
	spctl --assess --type execute -v $(APP)
	@echo "Notarised and stapled: $(DMG)"

release: notarize

run: app
	open $(APP)

clean:
	rm -rf .build
