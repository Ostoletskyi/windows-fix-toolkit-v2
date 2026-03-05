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

## Требования
- Windows 10/11
- PowerShell 5.1 (обязательно), PowerShell 7 — по возможности
- Для `Repair` и `Full` нужен запуск от администратора

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



## Git monitor menu (Bash)
Добавлена сопровождающая утилита `bin/project-git-monitor.sh` с меню:
1. **Пул** — `git fetch --all --prune` + `git pull --ff-only`
2. **Пуш** — отправка локальных изменений (`git push`, при необходимости предложит commit)
3. **Решения очистки дерева** — локальная очистка, hard sync к upstream, force push (`--force-with-lease`), stash
4. **Запуск основного меню** — вызов `bin/windowsfix-menu.sh`

Запуск:
```bash
bash ./bin/project-git-monitor.sh
```

## Bash-меню запуска (удобный launcher)
Добавлен скрипт `bin/windowsfix-menu.sh`, который показывает интерактивное меню режимов и умеет добавлять флаги (`-NoNetwork`, `-AssumeYes`, `-Force`, `-ReportPath`).

Запуск:
```bash
bash ./bin/windowsfix-menu.sh
```

Скрипт автоматически ищет PowerShell в порядке:
1. `powershell.exe`
2. `powershell`
3. `pwsh`

## Параметры entrypoint
- `-Mode Diagnose|Repair|Full|SelfTest|DryRun`
- `-ReportPath <path>`
- `-LogPath <path>`
- `-NoNetwork`
- `-AssumeYes`
- `-Force`
- `-Verbose`
- `-Debug`

## Запуск smoke test
```powershell
powershell -ExecutionPolicy Bypass -File .\tests\smoke.tests.ps1
```

## Безопасность
- Нет отключения Defender/Firewall.
- Нет скрытых пользователей, бэкдоров, сторонней телеметрии.
- Рискованные шаги должны подтверждаться пользователем (в следующих итерациях расширения repair-пайплайна).
