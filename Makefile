APP = ".build/Headroom AI.app"

.PHONY: app run test clean

test:
	swift test

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/Headroom $(APP)/Contents/MacOS/Headroom
	codesign --force --deep --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build
