# Releases and updates

> `.github/workflows/ci.yml` builds and tests every push and pull request on Windows, macOS and Linux. Every push to `main` also replaces a single unsigned rolling GitHub release (tag `rolling`, titled `Weaver <version>-build.<run number>`), with a Windows zip, a macOS disk image for Apple Silicon, a Linux tarball and `SHA256SUMS.txt`. The version comes from `build.zig.zon`. The signed release workflow (`release.yml`) has been removed; the signing, installer and update-manifest pipeline described below is the design to restore from Git history when signed releases are wanted.

Create a GitHub repository and enable Actions. Protect the `release` environment and set these public variables:

| Variable | Purpose |
| --- | --- |
| `WEAVER_OAUTH_CLIENT_ID` | Optional OAuth app client ID, with device flow enabled. Without it, sign-in uses Git Credential Manager |
| `WEAVER_UPDATE_PUBLIC_KEY` | 32-byte Ed25519 public key encoded as 64 lowercase hex characters |
| `AZURE_SIGNING_ENDPOINT` | Artifact Signing regional service endpoint |
| `AZURE_SIGNING_ACCOUNT` | Consistent validated publisher account |
| `AZURE_SIGNING_PROFILE` | Public trust certificate profile |
| `APPIMAGE_TOOL_SHA256` | SHA-256 for the chosen AppImage packaging tool |

Secrets: `WEAVER_UPDATE_PRIVATE_KEY` (32-byte Ed25519 seed in hex), Azure OIDC identity (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`), and Apple (`APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`). The update key is separate from OS signing certificates. Never commit private keys.

The GitHub device flow requests `repo`, `read:user` and `workflow`. The workflow scope supports pushing changes to GitHub Actions files; see [GitHub's OAuth scope documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps). It is used only by builds given an OAuth client ID; other builds take the token from Git Credential Manager's own sign-in. Expiring-token refresh and GitHub Enterprise account support remain future work.

Push a semantic version tag such as `v0.1.0`. The workflow builds Windows x64, Linux x64, macOS Intel and Apple Silicon. It signs Windows binaries and the Inno Setup installer, signs and notarizes macOS DMGs, packages Linux as AppImage, hashes the final installers, signs the exact manifest payload, and publishes all release assets only when packaging succeeds. Missing signing configuration fails the release. CI runs backend tests and compiles the GUI on each platform.

Linux currently requires a Wayland session because KnotsUI has no X11 backend. Native pickers use `xdg-desktop-portal` with a FileChooser backend installed by the desktop environment. Git, Git LFS and curl are runtime prerequisites; Linux GitHub sign-in additionally needs `secret-tool` and an unlocked Secret Service keyring. Git and Git LFS are deliberately not downloaded or installed silently.

The app checks a public GitHub release repository for `weaver-update.json`, verifies its Ed25519 signature using the build's pinned key, rejects older/equal versions and prereleases, downloads only HTTPS assets, and verifies SHA-256 before offering installation. Release artifacts must be public for the updater. Downloads never attach the GitHub repository-access token. Update installation is user initiated. On Windows, Inno Setup updates the same per-user install directory and app ID. On macOS the verified DMG opens for installation; Linux opens the verified AppImage. Fully automatic replacement/rollback on macOS and Linux remains a release-hardening task.

Build the stable Windows bootstrap separately:

```text
zig build bootstrap -Dheadless=true -Doptimize=ReleaseSafe -Drelease-repo=OWNER/REPO -Dupdate-public-key=PUBLIC_HEX_KEY
```

Sign `zig-out/bin/weaver-setup.exe` with your publisher's certificate and timestamp, then host that exact binary at a permanent download URL. Do not rebuild it for every release. It fetches and authenticates the newest manifest and Windows installer. Rebuild and re-sign it only if the bootstrap or trusted key needs to change. Ordinary installers retain the fixed Inno Setup AppId. The bootstrap is intentionally not automatically included in every release.

Signing preserves publisher identity and helps reputation accumulate. Microsoft controls SmartScreen reputation and can still warn on new signed releases. Azure Artifact Signing and EV certificates do not guarantee immediate trust. See [Microsoft's guidance](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation). Azure signing eligibility also depends on your country and whether you sign as an individual or organization; use an eligible service or an OV certificate provider if required.

Hosted macOS/Linux builds, notarization, real OAuth sign-in, public-release updates and installer upgrades need to be verified after your repository and credentials exist. Do not label those flows tested based on local compilation.
