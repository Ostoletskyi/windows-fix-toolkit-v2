# windows-fix-toolkit-v2

Windows Fix Toolkit (PowerShell 5.1+) для безопасной диагностики и базового восстановления Windows 10/11 штатными средствами.

## Что уже реализовано (MVP)
- Единый entrypoint: `bin/windowsfix.ps1`
- Модуль: `src/WindowsFixToolkit.psm1`
- Режимы:
  - `SelfTest` — проверка раннера и системных утилит (`dism`, `sfc`, `netsh`, `ipconfig`)
  - `Diagnose` — базовый системный snapshot, службы WU, DNS-проверка
  - `Repair` — минимальный шаг восстановления: `DISM /CheckHealth`
  - `Full` — `Diagnose` + `DISM /CheckHealth` + экспорт каталога логов
  - `DryRun` — показывает план без выполнения команд
- Отчётность и логи:
  - `report.json`
  - `report.md`
  - `toolkit.log` (внутренний лог toolkit)
  - `transcript.log` (только PowerShell transcript)
- Smoke tests: `tests/smoke.tests.ps1`

## Режимы
- `SelfTest`
- `Diagnose`
- `Repair` (MVP: DISM CheckHealth)
- `Full` (Diagnose + Repair + экспорт каталога логов)
- `DryRun` (план без выполнения опасных шагов)

## Быстрый старт
```powershell
# SelfTest
powershell -ExecutionPolicy Bypass -File .\bin\windowsfix.ps1 -Mode SelfTest

# Diagnose
powershell -ExecutionPolicy Bypass -File .\bin\windowsfix.ps1 -Mode Diagnose
```

Отчёты создаются в:
- по умолчанию: `Outputs\WindowsFix_<timestamp>` (timestamp включает миллисекунды, чтобы каждый запуск создавал уникальную папку)
- либо в пути, переданном через `-ReportPath`

Файлы в `Outputs\WindowsFix_<timestamp>`:
- `toolkit.log` — сообщения `Write-ToolkitLog` (устойчиво с retry при lock).
- `transcript.log` — вывод `Start-Transcript`/`Stop-Transcript`, не используется `Add-Content`.
- `report.json` и `report.md` — структурированный и человеко-читаемый отчёт.


## Bash-меню запуска (удобный launcher)
Добавлен скрипт `bin/windowsfix-menu.sh`, который показывает интерактивное меню режимов и умеет добавлять флаги (`-NoNetwork`, `-AssumeYes`, `-Force`, `-ReportPath`).

Запуск:
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
