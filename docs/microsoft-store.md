# Microsoft Store

Alongside the zip download, Windows builds are packaged as MSIX for the Microsoft Store. The Store accepts MSIX, MSI/EXE installers and PWAs; MSIX fits Weaver because the Store signs and hosts the package and delivers updates, so no code-signing certificate or download server is needed. An MSI or EXE submission would have to be signed with a purchased certificate and hosted at a permanent URL, and Weaver is not a web app.

## One-time setup

1. Register a developer account in [Partner Center](https://partner.microsoft.com/dashboard) and reserve an app name. `Weaver` was taken, so the reserved name is `Weaver - Git Desktop Client`; the package display name in `AppxManifest.xml` must match it exactly. Start and the taskbar still show `Weaver`.
2. Open **Product management > Product identity** for the app and copy three values into the `Package Windows for the Microsoft Store` step of `.github/workflows/ci.yml`:

| Workflow value | Partner Center value | Current value |
| --- | --- | --- |
| `MSSTORE_IDENTITY_NAME` | Package/Identity/Name | `Keone.Weaver-GitDesktopClient` |
| `MSSTORE_PUBLISHER` | Package/Identity/Publisher | `CN=02F98B6D-DB2E-4CA8-AC9A-1D0614AA298E` |
| `MSSTORE_PUBLISHER_DISPLAY_NAME` | Package/Properties/PublisherDisplayName | `Keone` |

The values are public (every package contains them) and case-sensitive. Run locally without them, the script packages with a development identity and warns; that package runs locally but the Store rejects it, and it does not collide with a Store install.

## Submitting a build

Every push to `main` attaches `Weaver-windows-x86_64.msix` to the rolling GitHub release. Download it, start a submission in Partner Center and upload it on the **Packages** page. The package is unsigned on purpose: the Store signs it after certification, and Windows will not install it directly.

Partner Center asks why the package needs its two restricted capabilities:

- `runFullTrust`: Weaver is a native Win32 desktop application that starts the user's installed Git.
- `unvirtualizedResources`: Git, Git hooks and Git LFS filters run as child processes and must read and write the user's real `AppData` (tool caches and configuration) rather than a private copy. Settings are kept in `%APPDATA%\Weaver`.

State in the listing that Git must already be installed. Do not pass `-Dupdate-public-key` to Store builds: it enables Weaver's own updater, and Store apps must update through the Store.

## Version numbers

The Store requires four numeric parts, a first part that is not 0, and a fourth part of 0. `scripts/package-windows-msix.ps1` therefore maps version `major.minor.patch` and the CI run number to `major+1.minor.run.0`, so `0.1.0` build 57 becomes `1.1.57.0`. The run number makes every build newer than the last. The app itself still reports `0.1.0-build.57`.

## Files

| File | Purpose |
| --- | --- |
| `packaging/windows/msix/AppxManifest.xml` | Package manifest template; the script fills in identity and version |
| `packaging/windows/msix/Assets/` | Store, Start and taskbar logos, exported by `scripts/generate-icons.py` |
| `scripts/package-windows-msix.ps1` | Stages the files, builds `resources.pri` and packs the MSIX with the Windows SDK |

## Building and testing locally

This needs the Windows SDK (`makeappx.exe` and `makepri.exe`).

```text
zig build -Doptimize=ReleaseSafe
./scripts/package-windows-msix.ps1
```

The result is `dist/Weaver-windows-x86_64.msix`. To run the packaged app without signing it, turn on Developer Mode in Windows and register the staged files, then remove them when done:

```text
Add-AppxPackage -Register dist\msix\layout\AppxManifest.xml
Get-AppxPackage -Name Weaver.Development | Remove-AppxPackage
```
