# Deep Recovery (Official Microsoft Source)

## Updated menu design
- New dedicated menu item: **Deep Recovery (Official Microsoft Source)**.
- Two-step confirmation gates:
  1. Yellow warning + `YES` gate.
  2. Red warning + exact phrase gate: `I UNDERSTAND THIS MAY CHANGE SYSTEM COMPONENTS`.

## Proposed module/file layout
- `bin/windowsfix-menu.sh` — UX, confirmations, launch wiring.
- `bin/windowsfix.ps1` — new mode and deep parameters.
- `src/WindowsFixToolkit.psm1` — deep stages (`DR-A..DR-E`) and orchestration.
- `src/config/error-signatures.json` — signature registry.
- `src/config/decision-policy.json` — policy mapping.
- `Outputs/<run>/journal/stage_*.json` — structured execution journal.

## PowerShell implementation plan
1. Detect OS family/arch/edition/build/language/elevation/online/pending reboot/WinRE hints.
2. Safeguard strategy:
   - Client: restore-point workflow (`Enable-ComputerRestore`, `Checkpoint-Computer`) when feasible.
   - Server: wbadmin-oriented recommendation path.
3. Source validation:
   - validate path, extension, reject unsupported `*.swm` automated flow.
4. Execute official source-assisted `DISM /RestoreHealth` (+`/Source`, `/LimitAccess` when provided), then `SFC`.
5. Parse/classify and emit decision records and root-cause summary.
6. Provide supported escalation (Windows 11 official reinstall path).

## Structured schemas
### Preflight result
```json
{ "stage": "DR-A", "os": {}, "online": true, "pendingReboot": false, "isElevated": true }
```
### Safeguard result
```json
{ "stage": "DR-B", "osFamily": "Client|Server", "safeguardAvailable": true, "artifact": "restorePoint|systemStateBackup|none", "reason": "..." }
```
### Source validation result
```json
{ "stage": "DR-C", "sourcePath": "...", "sourceType": "wim|esd|iso|swm", "matchStatus": "ok|mismatch|unsupported", "decision": "continue|abort" }
```
### Stage result
```json
{ "stage": "DR-D", "command": "...", "args": [], "exitCode": 0, "matchedSignatures": [], "decision": "continue", "humanSummary": "..." }
```
### Final report
```json
{ "overallPipelineStatus": "OK|WARN|FAIL", "rootCauseSummary": {}, "normalizedEvents": [], "policyDecisions": [], "safeToReboot": true, "confidence": "high|medium|low" }
```

## Decision matrix
- Client + restore point available -> continue deep repair.
- Client + restore point unavailable -> require `-DeepRecoveryAllowNoSafeguard` else stop.
- Client + policy-disabled restore -> warn, require stronger acknowledgement flag.
- Server + system-state backup available -> continue with warning/recommendation.
- Server + no valid backup target -> warn high risk; require explicit allow flag.
- Source mismatch -> abort; request matching official media.
- Source valid but repair fails -> classify + escalate to supported reinstall path.

## Final safety review
- No automatic ownership takeover of core Windows folders.
- No mass file-copy into System32/WinSxS/Servicing.
- No silent repair reinstall.
- No permanent security disabling.
- Direct file transplantation is unsupported/high-risk expert-only fallback and not primary strategy.
