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

Partner Center asks why the package needs its restricted capability:

- `runFullTrust`: Weaver is a native Win32 desktop application that starts the user's installed Git.

The package does **not** request `unvirtualizedResources`. AppData and HKCU write virtualization retain Windows defaults on both Windows 10 and Windows 11. There is no `desktop6:FileSystemWriteVirtualization` or `desktop6:RegistryWriteVirtualization` opt-out, and no Windows 11 `virtualization:ExcludedDirectories` or registry exclusions. The packaging script rejects any reintroduction of these declarations for review before submission.

### Resolving the 10.6.3 capability rejection

Upload a newly built MSIX with the denied capability removed; do not re-upload the rejected package. Use a build number greater than the last uploaded package. Replace the previous capability justification with the following submission note:

> This submission removes the denied unvirtualizedResources capability and the FileSystemWriteVirtualization=disabled declaration. Weaver retains Windows default AppData and HKCU write virtualization on Windows 10 and Windows 11, with no Flexible Virtualization exclusions. The remaining runFullTrust capability is required because Weaver is a native Win32 Git desktop client that invokes the user's installed Git. We are no longer requesting an exception for unvirtualized resources.

Weaver's own settings use the logical path `%APPDATA%\Weaver\settings.json` (with a temporary file alongside it during saves), subject to Windows virtualization. Do not promise that Store and portable installations share settings or that virtualized settings survive uninstall. Windows Credential Manager is accessed through `CredRead`, `CredWrite` and `CredDelete`; Weaver does not directly write its backing files or require an HKCU opt-out.

The previous justification assumed all Git tooling needed shared AppData. That is not established by the implementation. Git repository writes are selected by repository path; LFS setup uses `git lfs install --local`. Hooks, helpers and filters follow the user's Git configuration, so their potential paths cannot be honestly enumerated as one fixed AppData allowlist. Weaver does not sandbox those programs or enforce a filesystem write allowlist. Argument arrays, literal pathspecs, argument validation and operation timeouts constrain command invocation, but do not restrict the files a configured helper can write. Git itself may invoke shells for configured hooks/helpers; Weaver's own helper shell snippet quotes its executable path and contains no repository-supplied command text.

Before resubmitting, test the **packaged** app on Windows 10 and Windows 11 with a disposable repository outside AppData:

- Save settings, restart the packaged app and verify they reload. Check any existing settings from a previous installation separately.
- Stage, commit, fetch and push; verify the configured commit hook runs. Check SSH/signing if supported by the test configuration.
- Sign in with Git Credential Manager, restart, then fetch/push using the stored credential; also check Weaver's own sign-in/sign-out.
- Enable LFS locally, then track, commit, upload and download a disposable LFS file; check the resulting file contents.
- Exercise a representative configured helper/hook that creates new AppData files, and check whether it needs to share those files with an external process.

Source inspection and successful MSIX packing do not prove these runtime checks. If a required integration fails specifically because of redirection, capture the exact process and required AppData directory before considering an exception. Windows 11 can use named directory exclusions, but those still require the restricted capability; Windows 10 has no equivalent fine-grained fallback. Do not disable all AppData virtualization merely to accommodate arbitrary hooks. Any future reconsideration must state the actual account type and a valid publisher support contact, and distinguish intended scope from enforced restrictions.

Microsoft references: [Flexible virtualization](https://learn.microsoft.com/en-us/windows/msix/desktop/flexible-virtualization), [Packaged desktop app behavior](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes).

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
