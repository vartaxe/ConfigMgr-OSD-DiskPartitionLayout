# Security

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/security/advisories/new) for security issues. If unavailable, contact [vartaxe@outlook.com](mailto:vartaxe@outlook.com). Do not publish disk serials, inventory, task-sequence logs, credentials, or internal deployment details in public issues.

## Safety model

- Treat a non-preview run as destructive: `clean` removes partition metadata and is not secure erasure.
- Test only on disposable disks before production use, and keep the task-sequence cache and logs off the selected disk.
- Use `-RequireUEFI` for Windows 11-only sequences; BIOS/MBR is not a Windows 11 compatibility workaround.
- Do not use this tool for in-place upgrades, hard-link migrations, OEM/prestaged media, or recovery repair.
- Keep WinPE storage drivers, PowerShell 5.1 components, Storage WMI, ConfigMgr COM access, and DiskPart validated together.
