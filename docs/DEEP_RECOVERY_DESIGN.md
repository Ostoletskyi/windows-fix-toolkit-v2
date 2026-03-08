# Deep Recovery (Official Microsoft Source) — Step 3

## Scope implemented in Step 3
Implemented:
- `SOURCE_DISCOVERY`
- `SOURCE_VALIDATION`
- `REPAIR_STAGE_DISM`
- `REPAIR_STAGE_SFC`
- `POSTCHECK`

Still stubbed by design:
- `ESCALATION_DECISION`
- `REINSTALL_PATH`

## SOURCE_DISCOVERY
Conservative pluggable discovery model:
- user-provided path (`-RecoverySourcePath`)
- known local paths (`C:\sources\install.wim/esd`, `C:\Windows\Sources\install.wim/esd`)
- mounted media probes (`<drive>\sources\install.wim/esd/swm`)
- explicit placeholder hook for future official download provider (not implemented)

## SOURCE_VALIDATION
Best-effort validation against running OS context:
- architecture
- edition/name hint
- version/build compatibility (major/minor)
- language hint where present
- source type handling (`wim`, `esd`, `swm`, other)

Validation classes:
- `valid`
- `partial match`
- `mismatch`
- `unsupported`
- `corrupted/unusable`

## REPAIR_STAGE_DISM
- Executes conservative `DISM /Online /Cleanup-Image /RestoreHealth`.
- Uses ` /Source:<path> /LimitAccess` when a validated local source exists.
- Normalizes outcomes into categories:
  - toolkit internal execution failure
  - source problem
  - servicing/component store problem
  - environment/permissions problem
  - success / partial success / failed / inconclusive

## REPAIR_STAGE_SFC
- Executes `sfc /scannow` after DISM where appropriate.
- Uses same normalized classification model.

## POSTCHECK
- Executes:
  - `DISM /Online /Cleanup-Image /CheckHealth`
  - `sfc /verifyonly`
- Parses baseline signals and classifies:
  - `resolved`
  - `remains`
  - `inconclusive`
- Records reboot recommendation (pending reboot marker based).

## Reporting updates
Deep Recovery step report now includes:
- source validation status
- DISM/SFC outcomes and classifications
- postcheck classification and reboot recommendation
- strong-ack requirement state

## Step 4 integration note
Step 4 should consume Step 3 outputs (`sourceValidationResult`, `dismResult`, `sfcResult`, `postcheckResult`) to drive supported escalation/reinstall policy decisions only.
