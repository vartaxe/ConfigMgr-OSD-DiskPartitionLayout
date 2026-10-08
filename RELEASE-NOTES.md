# Release notes

## v1.0.2

Version 1.0.2 corrects published version and website metadata without changing
disk-selection or partitioning behavior.

### Fixed

- Identifies the root and packaged scripts, README, Pages site, and
  task-sequence guide consistently as version 1.0.2.
- Links the Pages site to the latest release and retains its canonical source
  README link instead of an excluded relative Pages path.
- Adds regression coverage so release metadata cannot silently drift again.

### Validation boundary

Windows PowerShell 5.1 validation passed all 64 Pester tests,
PSScriptAnalyzer, root/package byte parity, and complete checksum verification.
Live ConfigMgr, WinPE, firmware, storage-driver, OS-image, and disposable-disk
acceptance testing remains required before rollout. Version 1.0.2 is not
field-certified.

## v1.0.1

Version 1.0.1 is a safety and integrity maintenance release.

### Fixed

- Rejects task-sequence content and script paths that use a DNS alias resolving
  to the local computer, and fails closed when a UNC host cannot be resolved.
- Verifies every maintained file against `CHECKSUMS.txt`, rejecting malformed,
  duplicate, missing, extra, or mismatched entries.
- Defines deterministic repository line endings for reproducible script and
  manifest bytes.

### Updated

- Documents the Windows 11 26H1 new-hardware boundary, the ConfigMgr 2603+
  requirement for Windows 11 26H2, current ADK architecture constraints, and
  MDT retirement.
- Expands automated coverage for local FQDNs, alternate local DNS aliases, and
  unresolved network hosts.

### Validation boundary

Windows PowerShell 5.1 validation passed all 63 Pester tests, PSScriptAnalyzer,
root/package byte parity, and complete checksum verification. Live ConfigMgr,
WinPE, firmware, storage-driver, OS-image, and disposable-disk acceptance
testing remains required before rollout. Version 1.0.1 is not field-certified.

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
