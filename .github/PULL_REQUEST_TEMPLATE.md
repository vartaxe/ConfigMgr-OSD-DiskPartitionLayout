## Summary

Describe the focused change and the risk or deployment problem it addresses.

## Safety impact

- Explain how the fail-closed target-selection and pre-clean guards are preserved.
- Identify any changed support boundary, destructive behavior, or task-sequence requirement.
- Do not include disk serials, credentials, internal paths, or unredacted logs.

## Validation

- [ ] `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Invoke-Validation.ps1` passes.
- [ ] Root and packaged script copies remain byte-identical.
- [ ] New or changed logic has synthetic tests that do not modify hardware.
- [ ] Documentation reflects changed parameters, integration, or compatibility.
- [ ] Destructive behavior was tested only on disposable media, or the untested hardware boundary is stated explicitly.
