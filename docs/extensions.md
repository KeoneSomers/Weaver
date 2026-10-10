# Weaver extensions, API v1

Weaver provides a VS Code-style extension model: manifests, contributed commands, settings, install, enable and disable. It does **not** execute VS Code `.vsix` packages or the VS Code JavaScript API. A marketplace, automatic extension updates, embedded arbitrary UI and third-party VCS providers are not implemented yet.

The bundled GitHub, Git LFS, Appearance and Diagnostics extensions use the command registry. Third-party extensions are independent executables communicating through UTF-8 JSON lines over standard input/output. Any language can implement an extension, including Zig. Install the local manifest from the Extensions page; state persists between launches. New external extensions start disabled.

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
