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
- `Repair` (DISM CheckHealth + опционально DISM ScanHealth + SFC /scannow)
- `Full` (Diagnose + Repair + экспорт каталога логов)
- `DryRun` (план без выполнения опасных шагов)

## Быстрый старт
```bash
bash ./bin/windowsfix.sh -Mode SelfTest
bash ./bin/windowsfix.sh -Mode Diagnose
bash ./bin/windowsfix.sh -Mode DryRun
```

- Для `Repair` и `Full` без прав администратора ожидаем `ExitCode=2` и шаг `Admin check: FAIL` (это корректное поведение, не падение меню).


## Где сканирование системы
Сканирование выполняется в режиме `Repair` и `Full`:
1. `dism.exe /Online /Cleanup-Image /CheckHealth`
2. `dism.exe /Online /Cleanup-Image /ScanHealth` (по подтверждению)
3. `sfc.exe /scannow` (по подтверждению)

Чтобы запускать эти шаги без дополнительных вопросов, используйте флаг `-AssumeYes` (или `-Force`).
В `DryRun` шаги показываются как план (`SKIPPED`), без реального запуска.

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


## Понятный вывод результата и индикация процесса
В `bin/windowsfix-menu.sh` добавлены:
- Чистое меню без лишних индикаторов (пункты 1–6 + 0).
- Анимация выполнения во время запуска (вращающаяся палочка `|/-\`).

- В основном окне выполнения (включая elevated-окно) показывается пошаговый прогресс в процентах (`[PROGRESS]`) и спиннер активности для внешних команд (`[STEP] | / - \`).
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
