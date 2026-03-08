# Deep Recovery (Official Microsoft Source) — Step 2

## Scope implemented in Step 2
- Implemented `PREFLIGHT`.
- Implemented `SAFEGUARD_CHECK`.
- Implemented `SAFEGUARD_ATTEMPT`.
- Populated related schema/report fields.
- Kept later phases (`SOURCE_*`, `REPAIR_*`, `REINSTALL_PATH`) as stubs.

## Phase behavior
### PREFLIGHT
Collects and classifies:
- elevation
- OS family (Client/Server), edition, architecture, build/version, UI language
- pending reboot
- internet connectivity
- free disk space
- WinRE status (best effort)
- laptop/AC power state (best effort)

Classification:
- `ok`
- `warning`
- `blocking`

### SAFEGUARD_CHECK
Client:
- checks System Restore cmdlet availability
- checks already-enabled state on system drive (best effort)
- checks policy-disabled state (best effort)

Server:
- checks `wbadmin` availability
- checks backup target readiness heuristic (best effort)

Classifications:
- `safeguard already available`
- `safeguard unavailable but continuable`
- `safeguard blocked by policy`
- `safeguard unsupported`

### SAFEGUARD_ATTEMPT
Client:
- conservative attempt on system drive only
- enables restore protection if feasible
- sets conservative shadowstorage target
- attempts restore point creation

Server:
- readiness-only in this step (no forced backup execution)

Classifications:
- `safeguard successfully created`
- `safeguard failed`
- or passthrough from safeguard check

If safeguard cannot be guaranteed, result is explicitly logged and `requiresStrongAck=true` is set for later phases.

## Schemas populated
- `preflightResult`
- `safeguardCheckResult`
- `safeguardResult`
- `stageResult`
- `finalReport` (+ `requiresStrongAck`)

## Step 3 integration note
Step 3 should consume:
- `requiresStrongAck`
- `preflightResult`
- `safeguardResult`
and only then implement `SOURCE_DISCOVERY` + `SOURCE_VALIDATION` + repair execution policy gates.
