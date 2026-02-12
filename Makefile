# Daylight Mirror — build + install for Mac and Android
#
# Usage:
#   make install   — build Mac menu bar app + install to ~/Applications
#   make fetch-adb — download adb binary for embedding in the app bundle
#   make deploy    — build Android APK + install via adb
#   make run       — launch the menu bar app
#
# Prerequisites:
#   Mac:     Xcode Command Line Tools (xcode-select --install)
#   Android: adb (brew install android-platform-tools)
#   Android build: Android SDK + NDK (only needed if building APK from source)

APP_NAME := Daylight Mirror
APP_BUNDLE := $(HOME)/Applications/$(APP_NAME).app
BINARY := .build/release/DaylightMirror
CLI_BINARY := .build/release/daylight-mirror
APK := android/app/build/outputs/apk/debug/app-debug.apk

# Downloaded platform-tools (provides adb binary for embedding in app bundle)
PLATFORM_TOOLS_DIR := tools/platform-tools
ADB_BINARY := $(PLATFORM_TOOLS_DIR)/adb

.PHONY: mac android install deploy run clean test fetch-adb reset-permissions

# Build Mac menu bar app
mac:
	@echo "Building Mac app..."
	swift build -c release
	@echo "Done: $(BINARY)"

# Build Android APK (requires Android SDK + NDK)
android:
	@echo "Building Android APK..."
	cd android && ./gradlew assembleDebug
	@echo "Done: $(APK)"

# Download Android platform-tools (provides adb binary) if not already cached.
# The binary is ~6MB and gets embedded in the .app bundle for zero-config setup.
$(ADB_BINARY):
	@echo "Downloading Android platform-tools..."
	@mkdir -p tools
	@curl -sL https://dl.google.com/android/repository/platform-tools-latest-darwin.zip -o tools/platform-tools.zip
	@unzip -qo tools/platform-tools.zip -d tools/
	@rm tools/platform-tools.zip
	@echo "Downloaded adb: $(ADB_BINARY)"

fetch-adb: $(ADB_BINARY)
	@echo "adb binary ready: $(ADB_BINARY)"

# Install Mac app to ~/Applications as a proper .app bundle
install: mac
	@echo "Installing $(APP_NAME)..."
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(BINARY) "$(APP_BUNDLE)/Contents/MacOS/DaylightMirror"
	@cp $(CLI_BINARY) "$(APP_BUNDLE)/Contents/MacOS/daylight-mirror"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@# Embed bundled adb if available (run 'make fetch-adb' first)
	@if [ -f "$(ADB_BINARY)" ]; then \
		cp "$(ADB_BINARY)" "$(APP_BUNDLE)/Contents/Resources/adb"; \
		chmod +x "$(APP_BUNDLE)/Contents/Resources/adb"; \
		echo "Embedded bundled adb"; \
	else \
		echo "No bundled adb (run 'make fetch-adb' to embed). Will use system adb."; \
	fi
	@# Embed companion APK if available (run 'make android' first)
	@if [ -f "$(APK)" ]; then \
		cp "$(APK)" "$(APP_BUNDLE)/Contents/Resources/app-debug.apk"; \
		echo "Embedded companion APK"; \
	else \
		echo "No APK found (run 'make android' to build). Auto-install will be skipped."; \
	fi
	@codesign --force --deep -s - "$(APP_BUNDLE)"
	@echo "Installed: $(APP_BUNDLE)"
	@echo "Open from Spotlight or: open \"$(APP_BUNDLE)\""

# Deploy APK to connected Daylight via adb
deploy:
	@if [ ! -f "$(APK)" ]; then echo "APK not found. Run 'make android' first (requires Android SDK)."; exit 1; fi
	@echo "Installing APK on device..."
	adb install -r "$(APK)"
	@echo "Done. Open 'Daylight Mirror' on your device."

# Launch the menu bar app
run: mac
	@open "$(APP_BUNDLE)" 2>/dev/null || $(BINARY)

# Set up adb reverse tunnel (for USB connection)
tunnel:
	adb reverse tcp:8888 tcp:8888
	@echo "Tunnel ready: device:8888 → mac:8888"

# Reset TCC permissions (needed after reinstall since ad-hoc codesign invalidates them)
reset-permissions:
	@echo "Resetting TCC permissions for Daylight Mirror..."
	@tccutil reset ScreenCapture com.daylight.mirror
	@tccutil reset Accessibility com.daylight.mirror
	@echo "Done. Reopen the app to re-grant permissions."

# Run unit tests
test:
	swift test

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"
	@echo "Cleaned"
