# Weaver extensions, API v1

Weaver provides a VS Code-style extension model: manifests, contributed commands, settings, install, enable and disable. It does **not** execute VS Code `.vsix` packages or the VS Code JavaScript API. A marketplace, automatic extension updates, embedded arbitrary UI and third-party VCS providers are not implemented yet.

The bundled Git extension owns machine-level Git version detection and installation assistance. GitHub, Git LFS, Appearance and Diagnostics provide the other bundled tools. Third-party extensions are independent executables communicating through UTF-8 JSON lines over standard input/output. Any language can implement an extension, including Zig. Install the local manifest from the Extensions page; state persists between launches. New external extensions start disabled.

Git's installed version appears immediately left of Weaver's version in the status bar. Click it for details, a manual check, or installation instructions. A small **Install Git** or **Update available** action appears when appropriate. Detection runs at startup and every five minutes independently of repository scans; unattended update checks run once on launch, then at most once per day while Weaver stays open. Disable the Git extension to hide the indicator and stop checks, or set its `git.check_updates` setting to `false` to keep local detection without update checks. All installation actions require a deliberate button click in the Git dialog; Weaver never installs Git automatically.

On Windows, registered Git for Windows installations use WinGet's CLI with the exact `Git.Git` package, matching the existing user or machine installation scope. Update checks read the package WinGet can actually install, including Windows rebuild numbers; an upstream release can arrive before its WinGet package. Missing Git uses WinGet install. Weaver runs these commands with silent installer mode, retains their output and waits for completion. Windows may still require a UAC administrator prompt. There is no fallback from upgrade to install and no overriding pins, checksum validation or architecture checks. The detached `git update-git-for-windows` GUI updater is no longer used. If WinGet is absent or cannot identify the existing installation, Weaver provides instructions and reports the problem without replacing another Git installation. Portable or custom installations get official instructions. On macOS, verified Homebrew installations use the stable formula metadata and Homebrew CLI install/upgrade; pinned Git stays pinned. Missing Git without Homebrew opens Apple's Command Line Tools installer. Apple-managed Git updates stay with Software Update. On Linux, verified APT or DNF ownership enables a scoped CLI Git install/update through `pkexec` and the system's graphical administrator prompt. Update availability uses the local distribution package cache, including package revisions and backported fixes; refresh system update metadata to see newly published packages. Other distributions, custom installations, unavailable managers, or missing privilege agents use [Git's platform installation instructions](https://git-scm.com/install/). No repositories, hooks, LFS filters, or credentials are changed by these probes.

The version has a small red dot when Git is missing or its version cannot be read, amber when a stable update is confirmed available, and green when a successful check finds no newer update from the appropriate release source or distribution package cache. The dot stays neutral while update status is unknown, including disabled checks, network failures, pinned versions and installations whose updates are controlled by another manager. A successful local version probe alone never marks Git as up to date. Weaver preserves the executable selected by PATH, including symlinks and shims. Both that path and its resolved target are checked before selecting a system updater. Known mise, asdf, Nix, Scoop, Chocolatey, MacPorts and Conda installations are identified in the Git dialog and use their manager's instructions, preserving version selections, profiles and pins. Chocolatey package receipts take priority over a matching registered Git for Windows installation. Homebrew ownership detection also works on Linux. Unknown shims and custom installs never receive an automatic system replacement. For these managed installations, automatic system release checks are deferred to the owning manager; **Manage Git with …** opens the manager's documentation.

The Git dialog retains the last command result, full exit code (including Windows HRESULTs), and terminal output. Successful CLI exit alone is insufficient: Weaver must detect Git after installation, or observe a newer Git version after an update, before reporting completion. An unchanged or unavailable version remains an explicit incomplete result, even if a command exits with zero. Apple's developer-tools handoff is reported separately. Use **Check again** after that installer finishes; restart Weaver when installation changes its inherited PATH. Network failures retain local version detection and never claim that Git is current.

Example manifest:

```json
{
  "api_version": 1,
  "id": "example.audit",
  "name": "Repository Audit",
  "publisher": "Your name",
  "version": "1.0.0",
  "description": "Summarize repository health.",
  "executable": "C:/path/to/audit.exe",
  "permissions": ["repository_read", "process_execution"],
  "commands": [{"id": "audit.run", "title": "Audit repository"}],
  "settings": [{"id": "audit.label", "title": "Report label", "default": "Repository health"}]
}
```

Executables must have absolute paths. The host starts the executable with the repository as its working directory and sends:

```json
{"api_version":1,"method":"command.execute","command":"audit.run","repository":{"path":"C:/work/repo","provider":"git"},"arguments":[],"configuration":{"audit.label":"Repository health"}}
```

Write a UTF-8 response or plain text to stdout, diagnostics to stderr, and return zero on success. Weaver displays the output. Standard output and error are bounded to 8 MiB each and jobs have a 15-minute deadline. Secrets are not passed through this protocol. The executable gets the normal user environment.

Settings in API v1 are strings, editable in the extension's card and persisted per extension. Keep secrets in an OS credential store, not extension settings. Command and setting IDs must be unique within their scope. External commands cannot reuse registered command IDs.

Build the working Zig example with `zig build extension-example -Dheadless=true`. Copy `examples/repository-audit/manifest.template.json`, set `executable` to the absolute path of `zig-out/bin/weaver-repository-audit` (with `.exe` on Windows), and install it in Weaver. Enable the extension, adjust its report label, and run **Audit this repository**. Source: `src/extension_example.zig`.

Permissions are declared for review; they are **not an OS sandbox**. External extensions can access files and network with your user account. Weaver shows an explicit execution confirmation with the executable path before every external command. Enable only extensions you trust. External manifests cannot contribute built-in Git operations; the `operation` field is only honored for bundled extensions.

The version-control provider interface lives in `src/provider.zig`; UI models live in `src/model.zig`. Providers advertise capabilities and supply snapshots, revisions and operations. Git is the sole registered provider in this release. Revision IDs are opaque strings.
