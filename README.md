# PS

## Legacy telemetry cleanup

Run `uninstall-Telemeter.ps1` from an elevated Windows PowerShell 5.1+
session, or directly as LocalSystem. Use 64-bit PowerShell on 64-bit Windows.

```powershell
.\uninstall-Telemeter.ps1
# Already running as SYSTEM, or explicitly do not want automatic escalation:
.\uninstall-Telemeter.ps1 -SkipSystemPass
```

Administrator mode starts cleanup directly as SYSTEM using PsExec by default,
before touching services, tasks or deployment files. It returns the SYSTEM
child's verified result, including `3010`, without mixing in ADMIN-pass errors.
PsExec must have a valid Microsoft Authenticode signature. A missing copy is
downloaded over HTTPS; download/signature/execution failures are reported as
failures, not success. Downloads use a temporary file and are published only
after signature verification; interrupted downloads are cleaned up.
An existing trusted copy can be supplied using
`-PsExecPath`. `-AsSystemPass` is an internal switch and requires a real
LocalSystem token; it does not grant privileges.

### Removal scope

- Service: exactly `WinTelemetrySvc`. It is disabled and stopped before deletion
  through the Service Control Manager. If a hardened service descriptor denies
  deletion (access denied), its DACL is reset with `sc.exe sdset` and deletion is
  retried; if the SCM still refuses, the service's registry key is removed
  directly after reclaiming ownership. Shared service-host processes are not
  indiscriminately killed.
- Scheduled tasks: exactly `WinTelemetrySvcMaintenance`, in any task folder.
- **All `TelemetryUpdate*` items** under local AppData in registered profiles
  (including profiles on other drives), ordinary profiles under the system
  drive's Users folder, the current profile, SYSTEM's native/WOW64 profiles,
  LocalService and NetworkService. This deliberately includes newer deployments
  with matching folder names; back up anything needed first.
- Processes whose executable paths are inside those deployment locations are
  terminated, regardless of executable name. Process identity is rechecked.

Cleanup and verification use the same discovery rules. Locked files, denied
access, failed enumeration and unknown executable paths for
`TelemetryMainUpdate.exe` are reported, not treated as absence. Reparse points
inside deployment trees are refused to avoid deleting linked external data.
No ACL takeover, automatic reboot or deferred arbitrary file deletion is used.

`-TimeoutSeconds` controls individual process/service waits (default 30, range
1-300). Stop other deployment tools while cleaning: a separate installer or
watchdog can recreate items after any point-in-time verification.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Verification found no targeted services, tasks, processes or files, with no recorded cleanup errors. |
| `1` | Cleanup or verification failed, or leftovers remain. Inspect warnings, resolve the cause, and rerun (as SYSTEM if needed). |
| `3010` | Only service entries remain after accepted deletion requests; restart Windows and rerun to confirm removal. |

SYSTEM cleanup verifies results before returning. If already SYSTEM, PsExec
is not launched again. `-SkipSystemPass` explicitly opts into current-token
cleanup; use it from SYSTEM for protected services. If SYSTEM escalation fails,
cleanup fails without silently falling back to Administrator mode.
Errors during cleanup are retained; a clean rerun is needed for success.
Deletion can require a restart while other applications hold service handles.
No script can guarantee removal despite arbitrary OS protection, disk errors,
or another process actively recreating the deployment.

### Tests

```powershell
pwsh -NoProfile -File ./tests/uninstall-Telemeter.Tests.ps1
```

The dependency-free tests parse the script and exercise cleanup/verification
functions with mocked Windows operations. They do not remove real services,
tasks, processes or deployment files. Actual Windows integration testing is
still required on a disposable Windows machine before production deployment.