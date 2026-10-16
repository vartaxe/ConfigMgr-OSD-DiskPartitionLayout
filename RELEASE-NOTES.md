# Release notes

## v1.0.0

This is the **2026-10-16 consolidated v1.0.0 baseline**, prepared after an explicit
maintainer version reset. Earlier downloads with
the same version label may contain different bytes; identify this baseline by
the SHA-256 sidecar published with the current release asset.

### Included

- A guarded Windows PowerShell 5.1 disk-layout engine for ConfigMgr WinPE.
- Fail-closed target selection, firmware and storage checks, preview support,
  post-format verification, documentation, artwork, and automated tests.
- A versioned source ZIP with a SHA-256 sidecar.

### Audit fixes

- Reject custom output names that alias hard-link migration or existing OS-target
  safety inputs before any output clearing. Failure cleanup cannot overwrite a
  rejected input name.
- Use the visible Pages brand text as its accessible link name.
- Align current script, documentation, and release metadata with this v1.0.0 baseline.

### Retained maintenance history

Earlier releases labeled v1.0.1 added local-network-alias source protection,
fail-closed UNC resolution, complete checksum validation, deterministic line
endings, and updated Windows/ConfigMgr/ADK compatibility guidance. The earlier
v1.0.2 release aligned version and website metadata and added regression coverage.
Those changes are retained here; their original validation counts are historical,
not evidence for this new snapshot.

### Validation boundary

Automated validation covers parsing, static analysis, planning, target-selection
logic, safety guards, and synthetic postconditions without writing to hardware.
Live ConfigMgr, WinPE, firmware, storage-driver, OS-image, and disposable-disk
acceptance testing remains required before rollout. Version 1.0.0 is not
field-certified.
