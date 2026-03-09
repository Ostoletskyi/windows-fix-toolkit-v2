# windows-fix-toolkit-v2

Windows Fix Toolkit: **утилиты выполняются на PowerShell 5.1**, а bash используется как launcher-меню.

## Что сделано
- Основной runtime: `bin/windowsfix.ps1` + `src/WindowsFixToolkit.psm1`
- Bash launcher-меню: `bin/windowsfix-menu.sh`
- Git monitor: `bin/project-git-monitor.sh`
- Отчёты и логи:
  - `report.json`
  - `report.md`
  - `toolkit.log`
  - `transcript.log`
- Bash smoke test: `tests/smoke.sh`

## Режимы
- `Diagnose`
- `Repair` (по стадиям readiness -> DISM -> SFC -> subsystem -> postcheck)
- `Full` (Diagnose + Repair + Post-check)
- `DeepRecovery` (Official Microsoft Source, double confirmation; Step 4 adds escalation/reinstall-path policy + final reporting)
- `DryRun` (PLANNED-план без изменений)

## Быстрый старт
```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\windowsfix.ps1 -Mode Diagnose
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\windowsfix.ps1 -Mode Repair
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\windowsfix.ps1 -Mode DryRun
```

- Для `Repair` и `Full` без прав администратора ожидаем `ExitCode=2` и шаг `Admin check: FAIL` (это корректное поведение, не падение меню).



> Важно: `DryRun` не запускает ремонтные действия (DISM/SFC fix), но выполняет безопасную диагностику и анализ доступных логов.
> Поэтому в `DryRun` ремонтные стадии отмечаются как `PLANNED` и не выполняются.

## Где сканирование системы
Сканирование выполняется в режиме `Repair` и `Full`:
1. `dism.exe /Online /Cleanup-Image /CheckHealth`
2. `dism.exe /Online /Cleanup-Image /ScanHealth` (по подтверждению)
3. `sfc.exe /scannow` (по подтверждению)

Чтобы запускать эти шаги без дополнительных вопросов, используйте флаг `-AssumeYes` (или `-Force`).
В `DryRun` шаги показываются как план (`PLANNED`), без реального запуска.

## Параметры
- `-Mode Diagnose|Repair|Full|DeepRecovery|SelfTest|DryRun`
- `-ReportPath <path>`
- `-LogPath <path>`
- `-NoNetwork`
- `-AssumeYes`
- `-Force`
- `-RepairProfile Quick|Normal|Deep`
- `-DiagnoseProfile Quick|Normal|Deep`
- `-UiVerbose`

## Меню
```bash
bash ./bin/windowsfix-menu.sh
```

## Git monitor
```bash
bash ./bin/project-git-monitor.sh
```

## Smoke test
```bash
bash ./tests/smoke.sh
```

## Примечание
Bash оставлен как launcher-меню. Диагностика и ремонт выполняются PowerShell runtime.


## Понятный вывод результата и индикация процесса
В `bin/windowsfix-menu.sh` добавлены:
- Чистое меню без лишних индикаторов (пункты 1–6 + 0).
- Анимация выполнения во время запуска (вращающаяся палочка `|/-\`).

- В основном окне выполнения (включая elevated-окно) показывается живой однострочный спинер с таймером (`[WORK ⠋..] t=Ns`), без засорения консоли heartbeat-строками.
- Сводка результата после каждого запуска:
  - Mode, ExitCode, ReportPath
  - Количество шагов (OK/WARN/FAIL/SKIPPED)
  - Пути к артефактам (`report.json`, `report.md`, `toolkit.log`)
  - Список итогов по шагам.


## Автоповышение прав для административных режимов
В `bin/windowsfix-menu.sh` для режимов `Repair` и `Full` включено принудительное автоповышение прав:
- если текущая сессия не admin, меню запускает UAC-подтверждение через `powershell.exe` + `Start-Process -Verb RunAs`;
- После подтверждения UAC команды запускаются автоматически, вручную ничего вводить не нужно.
- после выполнения выводится стандартная сводка;
- если UAC отклонён или `powershell.exe` недоступен, будет `ExitCode=2` с понятным сообщением.


## Анализ логов и реальные рекомендации
После Diagnose/Repair/Full toolkit:
- собирает известные логи Windows в `Outputs/.../collected-logs` (CBS/DISM/WU, если доступны),
- анализирует их по сигнатурам проблем,
- выводит в итоге: либо `Problems not detected`, либо найденные проблемы,
- добавляет рекомендации по исправлению (например, повторный Repair + reboot + повторная Diagnose).


## Профили ремонта
- `Quick`: только `DISM CheckHealth` + SFC (быстрее, ScanHealth/RestoreHealth пропускаются).
- `Normal` (default): `CheckHealth` + `ScanHealth`, `RestoreHealth` только при необходимости.
- `Deep`: полный цикл `CheckHealth` + `ScanHealth` + `RestoreHealth` всегда.


## Профили диагностики
- `Quick`: минимальные проверки + сокращённый snapshot (быстрее).
- `Normal` (default): сбалансированный набор проверок.
- `Deep`: расширенный snapshot/валидация (дольше, подробнее).


## Deep Recovery (Official Microsoft Source)
- Отдельный режим с двойным подтверждением в меню (yellow + red gate).
- Сначала пытается сформировать safeguard (Client: restore point; Server: wbadmin workflow).
- Затем выполняет source-assisted DISM и SFC, с явной классификацией и policy decisions.
- Прямая трансплантация файлов в System32/WinSxS/Servicing не используется как primary strategy (unsupported/high-risk).
