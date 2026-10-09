---
title: ConfigMgr OSD Disk Partition Layout
---

<p align="center">
  <picture>
    <source media="(max-width: 720px)" srcset="assets/banner-compact.svg?v=1.0.2" width="640">
    <img src="assets/banner.svg?v=1.0.2" alt="ConfigMgr OSD Disk Partition Layout; Invoke-OSDDiskLayout.ps1; Windows PowerShell 5.1." width="1280" height="320">
  </picture>
</p>

## A guarded fresh-install layout for ConfigMgr WinPE

`Invoke-OSDDiskLayout.ps1` selects one approved target disk and creates a
firmware-appropriate UEFI/GPT or BIOS/MBR layout in one task-sequence step.
Ambiguous, unhealthy, unverified, or unsafe targets stop before disk cleanup.

> **Current version: 1.0.2. Not field-certified.** Automated tests do not
> replace validation with the actual ConfigMgr boot image, OS image, drivers,
> firmware, and disposable hardware.

## Before deployment

**In an active WinPE task sequence, running without parameters irreversibly
cleans and repartitions the selected disk.** `clean` removes partition
metadata; it is not secure erasure. Use only for a fresh install on disposable
test media until your environment-specific validation is complete.

Use `-RequireUEFI` for Windows 11-only sequences. BIOS/MBR is only suitable
for operating-system images that support legacy boot. A missing WinPE storage
driver can hide the intended disk; do not use automatic single-disk selection
on known multi-drive hardware.

## Documentation

<div class="guide-grid">
  <section class="guide-card">
    <h3><a href="TASK-SEQUENCE.html">Task-Sequence Integration</a></h3>
    <p>Step order, variables, safety settings, target selection, and rollout.</p>
  </section>
  <section class="guide-card">
    <h3><a href="docs/COMPATIBILITY-MATRIX.html">Compatibility Matrix</a></h3>
    <p>Supported profiles plus storage, firmware, and operating-system boundaries.</p>
  </section>
  <section class="guide-card">
    <h3><a href="SECURITY.html">Security</a></h3>
    <p>Destructive behavior, trust boundaries, and private vulnerability reporting.</p>
  </section>
  <section class="guide-card">
    <h3><a href="https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout#readme">Source README</a></h3>
    <p>Quick start, validation details, release files, and project links.</p>
  </section>
</div>

Use the [Source README](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout#readme)
for the complete quick start, validation boundary, and release-file guidance.

## Source and releases

The repository is authoritative. The [v1.0.2 release](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/releases/tag/v1.0.2)
includes a versioned source ZIP and SHA-256 sidecar. Verify the archive before
extraction, and keep the packaged script byte-identical to the root source copy.
Existing ConfigMgr packages do not update automatically.

Maintained by [Claudio Mendes (@vartaxe)](https://github.com/vartaxe), under
the [MIT license](LICENSE).

## Related projects

- [Copy OSD Logs to File Share](https://github.com/vartaxe/ConfigMgr-OSD-CopyOSDLogToFileShare) - companion diagnostics utility.
- [Add Computer to AD Group](https://github.com/vartaxe/ConfigMgr-OSD-AddComputerToADGroup) - post-join group membership utility.
