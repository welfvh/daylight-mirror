#!/bin/bash
# Manual release build script for retroactive v1.1 and v1.2 releases
#
# Usage: ./scripts/build-release.sh v1.1
#        ./scripts/build-release.sh v1.2
#
# Prerequisites:
#   - brew install create-dmg
#   - Android SDK installed (for APK build)
#   - gh CLI installed (for uploading to GitHub)

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <tag>"
  echo "Example: $0 v1.1"
  exit 1
fi

TAG="$1"
VERSION="${TAG#v}"

echo "Building release for $TAG (version $VERSION)..."

# Save current branch
CURRENT_BRANCH=$(git branch --show-current)

# Checkout tag
echo "Checking out $TAG..."
git checkout "$TAG"

# Build Mac binary
echo "Building Mac binary..."
cd server
swift build -c release
cd ..

# Create .app bundle
echo "Creating .app bundle..."
APP_BUNDLE="build/Daylight Mirror.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp server/.build/release/DaylightMirror "$APP_BUNDLE/Contents/MacOS/DaylightMirror"

# Update Info.plist with correct version
sed "s/<string>1.0<\/string>/<string>$VERSION<\/string>/g" Info.plist > "$APP_BUNDLE/Contents/Info.plist"

cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Codesign
echo "Codesigning..."
codesign --force --deep -s - "$APP_BUNDLE"

# Create DMG
echo "Creating DMG..."
if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "Daylight Mirror $VERSION" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Daylight Mirror.app" 175 120 \
    --hide-extension "Daylight Mirror.app" \
    --app-drop-link 425 120 \
    "DaylightMirror-$TAG.dmg" \
    "$APP_BUNDLE" || {
      echo "create-dmg failed, falling back to hdiutil..."
      hdiutil create -volname "Daylight Mirror $VERSION" \
        -srcfolder "$APP_BUNDLE" \
        -ov -format UDZO \
        "DaylightMirror-$TAG.dmg"
    }
else
  echo "create-dmg not found, using hdiutil..."
  hdiutil create -volname "Daylight Mirror $VERSION" \
    -srcfolder "$APP_BUNDLE" \
    -ov -format UDZO \
    "DaylightMirror-$TAG.dmg"
fi

# Build Android APK
echo "Building Android APK..."
cd android

# Update version in build.gradle.kts
sed -i.bak "s/versionName = \"1.0\"/versionName = \"$VERSION\"/" app/build.gradle.kts

./gradlew assembleDebug

# Restore original build.gradle.kts
mv app/build.gradle.kts.bak app/build.gradle.kts

cd ..

# Copy and rename APK
cp android/app/build/outputs/apk/debug/app-debug.apk "DaylightMirror-$TAG.apk"

echo ""
echo "Build complete!"
echo "  DMG: DaylightMirror-$TAG.dmg"
echo "  APK: DaylightMirror-$TAG.apk"
echo ""

# Upload to GitHub release
read -p "Upload to GitHub release $TAG? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Uploading to GitHub..."
  gh release upload "$TAG" "DaylightMirror-$TAG.dmg" "DaylightMirror-$TAG.apk"
  echo "Upload complete!"
else
  echo "Skipping upload. To upload manually, run:"
  echo "  gh release upload $TAG DaylightMirror-$TAG.dmg DaylightMirror-$TAG.apk"
fi

# Return to original branch
echo "Returning to $CURRENT_BRANCH..."
git checkout "$CURRENT_BRANCH"

echo "Done!"
