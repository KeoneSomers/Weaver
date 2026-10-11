#!/usr/bin/env sh
set -eu
version="$1"
arch="$2"
mkdir -p dist/Weaver.app/Contents/MacOS
cp zig-out/bin/weaver dist/Weaver.app/Contents/MacOS/
cp packaging/macos/Info.plist dist/Weaver.app/Contents/
mkdir -p dist/Weaver.app/Contents/Resources
cp assets/weaver.icns dist/Weaver.app/Contents/Resources/
cp -R zig-out/licenses dist/Weaver.app/Contents/Resources/
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" dist/Weaver.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" dist/Weaver.app/Contents/Info.plist
codesign --force --timestamp --options runtime --entitlements packaging/macos/entitlements.plist --sign "$APPLE_SIGNING_IDENTITY" dist/Weaver.app
hdiutil create -volname Weaver -srcfolder dist/Weaver.app -ov -format UDZO "dist/weaver-macos-$arch-$version.dmg"
codesign --timestamp --sign "$APPLE_SIGNING_IDENTITY" "dist/weaver-macos-$arch-$version.dmg"
xcrun notarytool submit "dist/weaver-macos-$arch-$version.dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
xcrun stapler staple "dist/weaver-macos-$arch-$version.dmg"
