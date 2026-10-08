# Release notes

## v1.0.0

This is the consolidated v1.0.0 baseline. Identify the release payload by the
SHA-256 sidecar published with the current release asset.

### Included

- A guarded Windows PowerShell 5.1 disk-layout engine for ConfigMgr WinPE.
- Fail-closed target selection, firmware and storage checks, preview support,
  post-format verification, documentation, artwork, and automated tests.
- Rejection of local DNS aliases and unresolved UNC hosts.
- Complete checksum verification with deterministic repository line endings.
- Current Windows 11, ConfigMgr, ADK architecture, and MDT retirement guidance.
- A versioned source ZIP with a SHA-256 sidecar.

### Validation boundary

Windows PowerShell 5.1 validation covers parsing, static analysis, planning,
target-selection logic, safety guards, root/package byte parity, complete
checksums, and synthetic postconditions without writing to hardware. Live
ConfigMgr, WinPE, firmware, storage-driver, OS-image, and disposable-disk
acceptance testing remains required before rollout. Version 1.0.0 is not
field-certified.
