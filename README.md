# Weaver

A native version-control desktop app written in **Zig**, using **KnotsUI** for the entire interface and **libgit2** for repository metadata, history and committed diffs, with Git providing filter-aware working-tree reads. Git is the first provider behind a provider-neutral UI model. No webview or Monaco editor.

**Development preview.** The Windows release-safety build and native screens have been checked locally. Production signing, hosted updates and macOS/Linux runtime validation remain outstanding.

## Windows preview

Extract `dist/Weaver-0.1.0-preview-windows-x86_64.zip` and run `weaver.exe` inside its folder. Keep `libgit2.dll` beside the executable. Install Git, Git LFS and curl, then add a repository in Weaver. This portable preview is unsigned; the release pipeline and stable installer bootstrap need your signing and GitHub configuration before public distribution.

## Build

Pinned dependencies: Zig **0.17.0**, KnotsUI `88bd83b4dc79f3178c9ca5345d5cb3c1c536f58f`, libgit2 **1.9.7**, Native File Dialog Extended **1.4.1**. Knots follows Zig development; keep the compiler and library revisions together. The bootstrap scripts fetch source dependencies and apply the checked-in Knots patches for native modal dialogs outside draw callbacks, cleanup of background results discarded during shutdown, and stable hover/context-menu hit targets while rebuilding the UI. Vendored checkouts and downloaded tools are ignored by Git.

Windows: install Zig with `zvm install 0.17.0`, CMake and Ninja, then:

```powershell
./scripts/bootstrap.ps1 -Zig "$env:USERPROFILE/.zvm/0.17.0/zig.exe"
& "$env:USERPROFILE/.zvm/0.17.0/zig.exe" build
& "$env:USERPROFILE/.zvm/0.17.0/zig.exe" build run
```

Linux needs Wayland development packages (`libwayland-dev`, `wayland-protocols`, `libxkbcommon-dev`, `libdbus-1-dev`, `pkg-config`), a desktop portal with a FileChooser backend, and a Vulkan 1.3 driver. macOS uses WebGPU. On Linux/macOS run `sh scripts/bootstrap.sh`, then `zig build` and `zig build run`.

Runtime requirements: Git, curl, and Git LFS for LFS repositories. Existing Git credential helpers, SSH configuration and agents remain available. Linux secure GitHub storage requires `secret-tool`. Tokens never go in settings or remote URLs.

```text
zig build test -Dheadless=true
zig build test-ui
zig build check -Dheadless=true
zig-out/bin/weaver-check /absolute/path/to/repository
```

## Workflows

- Add, initialize or clone repositories; switch between multiple folders; drag a folder into the app. Choosing or dropping an existing repository opens it directly with its configured remotes, including linked worktrees; folders without a repository show initialization and clone options.
- Native folder pickers for repository/clone locations, a JSON file picker for extension manifests, and file/folder pickers for path-based repository tools. Paths remain editable; cancelling preserves the previous value. Tool selections outside the current repository are rejected.
- Associate remotes using repository tools; clone GitHub public/private repositories with HTTPS or SSH.
- View staged and unstaged changes separately, file-type symbols, addition/deletion counts, highlighted unified diffs and commit history.
- Long change paths and project names truncate with an ellipsis; hover to see the full text. Right-click changes to view, stage/unstage, copy paths, open the containing folder, add the file, its folder or its file type to the root `.gitignore`, or discard tracked edits with confirmation. Right-click projects to open/refresh, open the folder or remote in a browser, copy the path, move the entry up, down, to the top or to the bottom of the list, or remove the workspace entry while keeping files on disk. Menu rows carry Lucide icons; discard and remove are shown in red.
- Switch between unified and side-by-side diffs; stage/unstage individual hunks, files or all changes; commit the staged set. Git identity, hooks, signing and LFS filters use your Git configuration.
- Compact Lucide toolbar buttons for refresh, fetch, pull and push, with full labels on hover and keyboard focus. Push and Pull highlight only when the current branch is ahead of or behind its upstream, with commit-count badges; zero counts stay hidden. Fetch, fast-forward pull, push, publish branches; create/switch/delete branches; merge, rebase, continue/abort; stash/pop; tag/delete; revert/cherry-pick; discard tracked edits with confirmation.
- GitHub device-flow authentication, OS credential storage and repository listing. Set the public OAuth client ID later in Settings.
- LFS setup, tracking, transfers, status and locks. The provider reconciles externally filtered file status through Git to avoid treating hydrated LFS files as modified.
- Rounded island workspace, five themes and a custom accent; offline Devicon file-type icons, persisted workspace/settings and bundled/installable extensions.
- Native branch picker and conflict recovery: inspect conflict markers, keep either side, stage edited resolutions, then continue or abort merges, rebases and cherry-picks.
- Automatic local refresh on the Changes page, preserving file selection. Optional background fetch of the current repository every five minutes, enabled in Settings and off by default, updates incoming commit counts without pulling or changing working files. The footer shows the relative time of the last successful fetch in Weaver, saved per repository; failed attempts do not advance it. Optional automatic signed-update checks on launch.
- Signed release manifests and verified update downloads; fixed installer identity and a stable Windows bootstrap.

Repository writes run in a serialized background queue. Opening and switching show animated loading feedback. File status appears before background line counts; only the selected working-tree diff is loaded, and long file lists render visible rows. You can switch repositories during a status scan; outdated scan, count and preview results are discarded. Writes stay disabled during a repository scan or another write. Git arguments are passed as arrays; repository content is never interpolated into a shell command. The app does not force-push, delete untracked files or hard-reset repositories automatically.

## Current boundaries

This is an initial implementation undergoing validation, **not a certified production-ready or GitHub Desktop parity release**. Remaining parity work includes selected-line staging, image diffs, richer conflict editing, PR creation/review, submodule/worktree management, full history pagination (currently 300 commits), native filesystem watching (refresh currently polls), extension marketplace/package installation, and automatic platform update replacement/rollback. Some advanced operations share a tools form rather than purpose-built dialogs. Only Git is registered; the provider interface and extension requests keep provider IDs explicit. Knots currently has no X11 backend or complex text shaping/IME composition. Individual working-tree text previews are limited to 2 MiB and 25,000 lines.

Local validation: 25 release-safety backend tests cover native snapshots, unborn repositories, real LFS pointer/filter behavior, partial staging, renames, merge conflict recovery, Unicode paths and missing final newlines, large-file statistics, relative/absolute workspace path deduplication, native-picker path validation, progressive status/count/preview reads, NUL-delimited rename parsing, extension validation, OAuth request construction, credential-host isolation and signed-update tampering. The compiled external Zig example was run through Weaver's extension host. Native Windows previews checked changes, unified/split diffs, themes/settings, extension management and live background refresh. Native Windows dialog checks covered in-app folder selection, cancellation, extension-manifest browsing, and standalone Unicode folder/file selection. These checks do not prove real GitHub sign-in, network LFS transfers, installer upgrades or other operating systems.

Large-repository measurements and the progressive loading design are in [repository performance](docs/performance.md).

See [extension API](docs/extensions.md) and [signing/release setup](docs/releases.md). OAuth and release endpoints are intentionally unconfigured until you create the GitHub app/repository. Release signing needs your own validated credentials.

## Third-party notices

KnotsUI and the embedded Devicon v2.17.0 file icon font are MIT licensed. libgit2 is GPLv2 with a linking exception. The embedded JetBrains Mono font is licensed under the SIL Open Font License. See `THIRD_PARTY_NOTICES.md`, `assets/Devicon-LICENSE.txt` and `assets/OFL.txt`. Weaver's own distribution license should be chosen by the project owner before publishing.
