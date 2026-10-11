#!/usr/bin/env sh
set -eu
version="$1"
mkdir -p dist/AppDir/usr/bin dist/AppDir/usr/share/applications dist/AppDir/usr/share/icons
cp zig-out/bin/weaver dist/AppDir/usr/bin/
cp packaging/linux/weaver.desktop dist/AppDir/
cp packaging/linux/weaver.desktop dist/AppDir/usr/share/applications/
cp assets/weaver.png dist/AppDir/weaver.png
# Retire the previous SVG even when reusing an existing AppDir.
rm -f dist/AppDir/weaver.svg
cp -R assets/icons/hicolor dist/AppDir/usr/share/icons/
ln -sf weaver.png dist/AppDir/.DirIcon
cp -R zig-out/licenses dist/AppDir/usr/share-weaver-licenses
cat > dist/AppDir/AppRun <<'EOF'
#!/usr/bin/env sh
HERE=$(dirname "$(readlink -f "$0")")
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/bin/weaver" "$@"
EOF
chmod +x dist/AppDir/AppRun
ARCH=x86_64 appimagetool dist/AppDir "dist/weaver-linux-x86_64-$version.AppImage"
