#!/usr/bin/env sh
set -eu
version="$1"
arch="$2"
mkdir -p dist/Weaver.app/Contents/MacOS dist/Weaver.app/Contents/Frameworks
cp zig-out/bin/weaver dist/Weaver.app/Contents/MacOS/
cp packaging/macos/Info.plist dist/Weaver.app/Contents/
mkdir -p dist/Weaver.app/Contents/Resources
cp assets/weaver.icns dist/Weaver.app/Contents/Resources/
cp -R zig-out/licenses dist/Weaver.app/Contents/Resources/
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" dist/Weaver.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" dist/Weaver.app/Contents/Info.plist
dylib=$(find .tools/git2/lib -name 'libgit2.*.dylib' -type f | head -n 1)
cp "$dylib" dist/Weaver.app/Contents/Frameworks/libgit2.1.9.dylib
original=$(otool -L zig-out/bin/weaver | awk '/libgit2/{print $1}')
install_name_tool -change "$original" '@executable_path/../Frameworks/libgit2.1.9.dylib' dist/Weaver.app/Contents/MacOS/weaver
install_name_tool -id '@executable_path/../Frameworks/libgit2.1.9.dylib' dist/Weaver.app/Contents/Frameworks/libgit2.1.9.dylib
codesign --force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY" dist/Weaver.app/Contents/Frameworks/libgit2.1.9.dylib
codesign --force --timestamp --options runtime --entitlements packaging/macos/entitlements.plist --sign "$APPLE_SIGNING_IDENTITY" dist/Weaver.app
hdiutil create -volname Weaver -srcfolder dist/Weaver.app -ov -format UDZO "dist/weaver-macos-$arch-$version.dmg"
codesign --timestamp --sign "$APPLE_SIGNING_IDENTITY" "dist/weaver-macos-$arch-$version.dmg"
xcrun notarytool submit "dist/weaver-macos-$arch-$version.dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
xcrun stapler staple "dist/weaver-macos-$arch-$version.dmg"
