# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-04-06

### Added

- XML-based `.dproj` sanitizer (`untDprojSanitizer`).
- ToolsAPI plugin integration for save/load workflows (`untLocalProjectSettings`).
- Shared local settings sidecar store (`untLocalDevSettingsStore`).
- CLI tool with single file, folder, wildcard and recursive (`/s`) modes.
- Sidecar file support: `*.dproj.teamowork.local`.
- Run-parameters persistence by configuration/platform matrix.
- Encoding preservation and robust sidecar recovery from invalid/empty XML.

### Changed

- Moved volatile run/debug settings out of committed `.dproj`.
- Unified plugin and CLI on a single shared sidecar persistence implementation.

### Fixed

- Reduced merge-conflict noise caused by volatile project options.
- Correct handling of disabled platforms and empty run-parameter values.
