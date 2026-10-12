# Application icon

`assets/weaver-source.png` is Weaver's approved two-tone artwork: three white vertical pillars joined by two muted grey diagonals on a charcoal tile. Keep this master and its alpha channel; every platform export uses the same artwork. All asset filenames and application identities use the Weaver name.

Regenerate with Python and Pillow:

```text
python -m pip install pillow
python scripts/generate-icons.py
```

| Asset | Use |
| --- | --- |
| `assets/weaver.png` | 1024 px PNG for general use and the AppImage root icon |
| `assets/weaver.ico` | Windows sizes 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 96, 128, 192 and 256 px |
| `assets/weaver.res` | Icon group 1, linked into the Windows application and bootstrap executable |
| `packaging/windows/msix/Assets/*.png` | Microsoft Store package logos: Store logo, app list icon and tiles at 100, 125, 150, 200 and 400 % scale, plus exact 16, 24, 32, 48 and 256 px taskbar icons |
| `assets/weaver.icns` | macOS 16, 32, 64, 128, 256 and 512 px standard icons; Retina representations for 16, 32, 128, 256 and 512 pt, up to 1024 px |
| `assets/icons/hicolor/*/apps/weaver.png` | Linux launcher icons at 16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512 and 1024 px |
| `assets/weaver.rgba` | 64 px RGBA export for asset previews |

The in-app sidebar badge uses the editable vector source `assets/weaver-badge.svg`. Every theme uses a black tile, white pillars and muted grey diagonal bridges. KnotsUI renders the SVG geometry as native vector commands; the border is aligned to the display's pixel grid and stays one physical pixel thick at different display scales. Rounded corners retain smooth antialiasing.

After editing the SVG, run `python scripts/generate-badge.py` and `zig fmt src/brand_badge_svg.zig`. The generated Zig geometry is checked in, so normal builds need no SVG library or Python runtime. The build checks the SVG's SHA-256 against the generated geometry and rejects stale exports.

Windows loads separate small and large resource icons into the native window and keeps them alive until the window is destroyed. The process and installed shortcut share `app.weaver.desktop` as their AppUserModelID; a Microsoft Store install keeps the identity of its package instead. The ICO also supplies the installer icon. Existing pinned shortcuts may need to be unpinned and pinned again after updating their executable or identity.

The macOS bundle references `weaver.icns` in `Info.plist`; `scripts/package-macos.sh` copies it into `Contents/Resources`. Run the `.app` bundle for its Dock icon.

Linux sets the Wayland app ID to `weaver`, matching `weaver.desktop`. Both the Zig install step and AppImage packaging include the desktop entry and hicolor icons. AppRun adds the bundled data directory to `XDG_DATA_DIRS`; desktop integration remains dependent on the host launcher. A raw development executable requires the desktop entry and icons to be installed in the desktop's application/icon search paths.

The master is a raster asset. Exports preserve its transparent outer corners and use Lanczos resampling for small sizes; the artwork is never redrawn as a different mark during export.
