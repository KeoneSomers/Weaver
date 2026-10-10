# Application icon

`assets/weaver-source.png` is the original approved artwork, generated with the built-in imagegen tool on 10 October 2026. Keep this master and its alpha channel; every platform export uses the same artwork. It is a raster logo, not an editable vector. The old placeholder SVG has been retired.

Regenerate with Python and Pillow:

```text
python -m pip install pillow
python scripts/generate-icons.py
```

| Asset | Use |
| --- | --- |
| `assets/weaver.png` | 1024 px PNG for general use and the AppImage root icon |
| `assets/weaver.ico` | Windows sizes 16, 20, 24, 32, 40, 48, 64, 96, 128, 192 and 256 px |
| `assets/weaver.res` | Icon group 1, linked into the Windows application and bootstrap executable |
| `assets/weaver.icns` | macOS bundle icon, including Retina representations up to 1024 px |
| `assets/icons/hicolor/*/apps/weaver.png` | Linux launcher icons from 16 to 1024 px |
| `assets/weaver.rgba` | 64 px RGBA pixels embedded for the KnotsUI sidebar badge |

Windows loads separate small and large resource icons into the native window and keeps them alive until the window is destroyed. The process and installed shortcut share `app.weaver.desktop` as their AppUserModelID. The ICO also supplies the installer icon. Existing pinned shortcuts may need to be unpinned and pinned again after updating their executable or identity.

The macOS bundle already references `weaver.icns` in `Info.plist`; `scripts/package-macos.sh` copies the generated file into `Contents/Resources`. Run the `.app` bundle for its Dock icon.

Linux sets the Wayland app ID to `weaver`, matching `weaver.desktop`. Both the Zig install step and AppImage packaging include the desktop entry and hicolor icons. AppRun adds the bundled data directory to `XDG_DATA_DIRS`; desktop integration remains dependent on the host launcher. A raw development executable requires the desktop entry and icons to be installed in the desktop's application/icon search paths.

The imagegen generation brief was:

> Use case: logo-brand. Create a new desktop app icon for Weaver, a native Git/version-control application. A bold woven W monogram made from two interlocking ribbon-like paths; the silhouette reads immediately as W, and one or two clean over-under crossings evoke weaving together branches. Simple balanced geometry, generous negative space, readable at taskbar size. Dark charcoal #222326 rounded-square tile with transparent corners. Use the established lavender #B4A0FF; a paler strand may distinguish crossings. Crisp flat vector-like mark, smooth curves, medium-bold ribbons. One centered icon, straight-on, square canvas, mark about 65 percent of tile width. No wordmark, captions, device mockup, watermark, additional symbols, thin details, literal spider or fabric; no dramatic gradients, texture, glow, bevels or 3D.
