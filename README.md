# Teamowork Friendly Dproj

A Delphi design-time plugin and CLI that keep volatile project settings out of committed project files.

The goal is to reduce merge conflicts in `.dproj` files for teams working on the same codebase with different local IDE/runtime preferences.

## The problem this plugin tries to solve

In Delphi teams, conflicts in `.dproj` files are often caused not by functional code changes, but by local IDE settings automatically written to the project file.

Typical examples:

1. Different active output platform across developers

Developer A saves with `Win32` active, while Developer B saves with `Win64` active. Even with no code changes, the project file changes and causes a merge conflict.

```xml
<!-- saved by developer A -->
<Platform Condition="'$(Platform)'==''">Win32</Platform>

<!-- saved by developer B -->
<Platform Condition="'$(Platform)'==''">Win64</Platform>
```

2. Different Run Parameters for local debugging

Each developer uses different runtime parameters (ports, config files, feature flags, tenant, local credentials). If these values remain in `.dproj`, every save adds noisy commit changes.

```xml
<!-- machine A -->
<Debugger_RunParams>--port=8080 --env=local</Debugger_RunParams>

<!-- machine B -->
<Debugger_RunParams>--port=8090 --env=staging</Debugger_RunParams>
```

3. Delphi installations with different platform support

In mixed teams, some developers have Android/Linux SDK support configured and others do not. Opening and re-saving the same project can add/remove platform nodes that are not part of the intended project targets, creating constant noisy diffs.

```xml
<!-- introduced on a machine with extra platform support -->
<Platform value="Linux64">False</Platform>
<Platform value="Android64">False</Platform>
```

Practical result: many commit conflicts on project files, even when no one changed application logic. This plugin separates local settings and keeps `.dproj` clean and stable in version control.



## What This Project Does

- Sanitizes `.dproj` files after save.
- Moves local run/debug settings to a sidecar file: `*.dproj.localcfg` which stays in the developer workspace without being part of the git repository.
- Supports command-line sanitization through `DprojSanitizerCli`.

## Target Platform Normalization

The sanitizer reads the enabled target platforms from the project itself (`<Platforms>` entries set to `True`) and keeps the project aligned with that list.

In practice it removes unsupported or disabled platform noise from sections that commonly drift across machines, such as:

- base platform `PropertyGroup` entries for non-enabled targets
- `Platforms` entries explicitly set to `False`
- unsupported platform nodes inside `Deployment`

This is especially useful in mixed teams where developers use different Delphi installations (for example, some with Android/Linux SDK support and others without it). Without normalization, opening/saving the same project on different machines often reintroduces platform-specific changes and merge conflicts.

With this plugin, only platforms intentionally enabled in the project remain stable in version control.

## Why It Is Useful

In Delphi teams, some settings are developer-specific and change often. When these values remain in `.dproj`, they generate noisy diffs and merge conflicts.

This project keeps those values local while preserving a clean, stable `.dproj` in source control.

## Components

- `untLocalProjectSettings.pas`
: IDE plugin integration via ToolsAPI notifiers.

- `untDprojSanitizer.pas`
: XML sanitizer for `.dproj`.

- `untLocalDevSettingsStore.pas`
: Shared sidecar persistence layer.

- `Tools/DprojSanitizerCli/DprojSanitizerCli.dpr`
: CLI tool for batch/automation usage.

## Sidecar Format

The plugin writes local settings to:

- `YourProject.dproj.localcfg`

Backward compatibility:

- Legacy files named `YourProject.dproj.teamowork.local` are still read.
- On next save, settings are written to `YourProject.dproj.localcfg`.

Stored data includes:

- Current active platform
- Run parameters matrix by build configuration and platform

Only non-empty values are persisted. Disabled platforms are not persisted.

## Build Requirements

- RAD Studio / Delphi 12 (Athens) or compatible ToolsAPI version
- `dcc64` / `dcc32` available in environment

## Build

### Package (plugin)

```powershell
Push-Location "c:\Athens\GitHub\TeamoworkFriendlyDproj"
dcc64 TeamoworkFriendlyDproj.dpk
Pop-Location
```

### CLI

```powershell
Push-Location "c:\Athens\GitHub\TeamoworkFriendlyDproj\Tools\DprojSanitizerCli"
dcc32 DprojSanitizerCli.dpr
Pop-Location
```

## CLI Usage

```powershell
DprojSanitizerCli <file|folder|wildcard> [/s]
```

Examples:

```powershell
DprojSanitizerCli "C:\Repo\MyProject.dproj"
DprojSanitizerCli "C:\Repo\*.dproj"
DprojSanitizerCli "C:\Repo" /s
```

## Source Control Recommendations

Never commit local sidecars or Delphi local files.

Recommended ignore rules are included in `.gitignore`.

## Known Limitations

- The plugin targets Delphi ToolsAPI behavior available in modern RAD Studio versions.
- If a sidecar XML file is empty/corrupt, the store recreates it on next save.
- Legacy sidecars with the old suffix are supported for reading and transparently migrated on save.
- Teams should agree on supported target platforms in the `.dproj` to avoid unexpected local filtering.

## License

MIT. See `LICENSE`.
