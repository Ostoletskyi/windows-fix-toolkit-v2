# windows-fix-toolkit-v2

Windows Fix Toolkit в **единой bash-среде** (без обязательного PowerShell runtime для оркестрации).

## Что сделано
- Единый bash entrypoint: `bin/windowsfix.sh`
- Bash toolkit-core: `src/bash_toolkit.sh`
- Меню запуска режимов: `bin/windowsfix-menu.sh`
- Git monitor: `bin/project-git-monitor.sh`
- Отчёты и логи:
  - `report.json`
  - `report.md`
  - `toolkit.log`
  - `transcript.log`
- Bash smoke test: `tests/smoke.sh`

## Режимы
- `SelfTest`
- `Diagnose`
- `Repair` (MVP: DISM CheckHealth)
- `Full` (Diagnose + Repair + экспорт каталога логов)
- `DryRun` (план без выполнения опасных шагов)

## Быстрый старт
```bash
bash ./bin/windowsfix.sh -Mode SelfTest
bash ./bin/windowsfix.sh -Mode Diagnose
bash ./bin/windowsfix.sh -Mode DryRun
```

## Параметры
- `-Mode Diagnose|Repair|Full|SelfTest|DryRun`
- `-ReportPath <path>`
- `-LogPath <path>`
- `-NoNetwork`
- `-AssumeYes`
- `-Force`

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
Старые PowerShell-файлы оставлены в репозитории как legacy-референс, но основной рабочий контур теперь полностью bash.


## Понятный вывод результата и прогресс
В `bin/windowsfix-menu.sh` добавлены:
- Индикатор выполнения в процентах для пунктов 1–5 прямо в меню.
- Прогресс выполнения выбранного действия (0% -> 20% -> 85% -> 100%).
- Сводка результата после каждого запуска:
  - Mode, ExitCode, ReportPath
  - Количество шагов (OK/WARN/FAIL/SKIPPED)
  - Пути к артефактам (`report.json`, `report.md`, `toolkit.log`)
  - Список итогов по шагам.
