# Release notes

## v1.0.0

This is the **2026-10-06 consolidated v1.0.0 baseline**. Earlier downloads with
the same version label may contain different bytes; identify this baseline by
the SHA-256 sidecar published with the current release asset.

### Included

- A guarded Windows PowerShell 5.1 disk-layout engine for ConfigMgr WinPE.
- Fail-closed target selection, firmware and storage checks, preview support,
  post-format verification, documentation, artwork, and automated tests.
- A versioned source ZIP with a SHA-256 sidecar.

### Validation boundary

Automated validation covers parsing, static analysis, planning, target-selection
logic, safety guards, and synthetic postconditions without writing to hardware.
Live ConfigMgr, WinPE, firmware, storage-driver, OS-image, and disposable-disk
acceptance testing remains required before rollout. Version 1.0.0 is not
field-certified.
