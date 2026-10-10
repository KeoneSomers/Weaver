#!/usr/bin/env sh
set -eu
version="$1"
mkdir -p dist/AppDir/usr/bin dist/AppDir/usr/lib
cp zig-out/bin/weaver dist/AppDir/usr/bin/
cp -L .tools/git2/lib/libgit2.so* dist/AppDir/usr/lib/
cp packaging/linux/weaver.desktop dist/AppDir/
cp assets/weaver.svg dist/AppDir/weaver.svg
cp -R zig-out/licenses dist/AppDir/usr/share-weaver-licenses
cat > dist/AppDir/AppRun <<'EOF'
#!/usr/bin/env sh
HERE=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/weaver" "$@"
EOF
chmod +x dist/AppDir/AppRun
ARCH=x86_64 appimagetool dist/AppDir "dist/weaver-linux-x86_64-$version.AppImage"
