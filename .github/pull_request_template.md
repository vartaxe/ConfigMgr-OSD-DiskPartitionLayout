## Summary

Describe the change and why it is needed.

## Validation

- [ ] `build\Invoke-Validation.ps1` passes on Windows PowerShell 5.1
- [ ] PSScriptAnalyzer returns no findings
- [ ] Pester 6.2.0 discovery and tests pass
- [ ] Full validation runs without `-SkipChecksums`; manifest matches worktree and candidate `git archive`
- [ ] Live results are recorded separately, with untested scenarios explicitly pending
- [ ] Documentation updated if behavior changed
- [ ] No credentials, internal values, or sensitive logs included
