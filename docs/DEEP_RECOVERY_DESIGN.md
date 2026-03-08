# Deep Recovery (Official Microsoft Source) — Step 1 Scaffold

## Updated menu design
- Dedicated menu item: **Deep Recovery (Official Microsoft Source)**.
- Double confirmation scaffold:
  1. Warning gate (yellow): requires `YES`.
  2. Severe acknowledgement gate (red): requires exact phrase `I UNDERSTAND THIS MAY CHANGE SYSTEM COMPONENTS`.
- Stage plan now explicitly shows scaffold phases for Step 1.

## Module/file layout (scaffold split)
- `bin/windowsfix-menu.sh` — menu + confirmation UX integration.
- `src/deeprecovery/orchestrator.ps1` — state-driven phase orchestration skeleton.
- `src/deeprecovery/preflight.ps1` — preflight phase stub.
- `src/deeprecovery/safeguard.ps1` — safeguard check/attempt stubs.
- `src/deeprecovery/sourceDiscovery.ps1` — source discovery stub.
- `src/deeprecovery/sourceValidation.ps1` — source validation stub.
- `src/deeprecovery/dismRepair.ps1` — DISM repair stub.
- `src/deeprecovery/sfcRepair.ps1` — SFC repair stub.
- `src/deeprecovery/postcheck.ps1` — postcheck stub.
- `src/deeprecovery/escalation.ps1` — escalation decision stub.
- `src/deeprecovery/reinstallPath.ps1` — reinstall path stub.
- `src/deeprecovery/classification.ps1` — classification/finalization stub.
- `src/deeprecovery/reporting.ps1` — report state wiring helpers.
- `src/deeprecovery/ui.ps1` — UI warning helpers.
- `src/deeprecovery/schemas.ps1` — schema/object templates.
- `src/deeprecovery/signatures.ps1` — signature placeholders.
- `src/deeprecovery/policy.ps1` — policy placeholders.
- `src/config/deeprecovery-signatures.placeholder.json` — config placeholder.
- `src/config/deeprecovery-policy.placeholder.json` — config placeholder.

## State phases (Step 1 skeleton)
- `PREFLIGHT`
- `SAFEGUARD_CHECK`
- `SAFEGUARD_ATTEMPT`
- `SOURCE_DISCOVERY`
- `SOURCE_VALIDATION`
- `REPAIR_STAGE_DISM`
- `REPAIR_STAGE_SFC`
- `POSTCHECK`
- `ESCALATION_DECISION`
- `REINSTALL_PATH`
- `FINAL_REPORT`

## Structured schemas / templates
### safeguardResult
```json
{ "available": false, "status": "NOT_ATTEMPTED", "type": "none", "reason": "scaffold", "details": [] }
```

### sourceValidationResult
```json
{ "sourceProvided": false, "sourceType": "unknown", "isValid": false, "matchConfidence": "unknown", "reason": "scaffold", "details": [] }
```

### stageResult
```json
{ "phase": "PREFLIGHT", "status": "PLANNED", "summary": "Scaffold phase placeholder", "decisions": [], "findings": [], "recommendations": [], "artifacts": [], "error": null }
```

### finalReport
```json
{ "feature": "Deep Recovery (Official Microsoft Source)", "scaffoldStep": 1, "phases": [], "safeguardResult": {}, "sourceValidationResult": {}, "overallStatus": "PLANNED", "confidence": "low", "nextStep": "Step 2: preflight+safeguard implementation" }
```

## How Step 2 plugs into this scaffold
- Replace each stub phase function with real implementation incrementally, preserving current phase names and transition tracking.
- Keep `Invoke-DeepRecoveryScaffold` as orchestration entrypoint, but switch per-phase status from `PLANNED/SKIPPED` to real `OK/WARN/FAIL` based on validated outcomes.
- Populate signature/policy placeholders with real deterministic rules and connect to classification output.
- Keep conservative defaults: no destructive/high-risk operation without explicit acknowledgement and auditable logging.
