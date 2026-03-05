# Windows Fix Toolkit - Исправления логирования

## 🔧 Что исправлено

### Проблема
Скрипт падал с ошибкой:
```
Export-ModuleMember: The Export-ModuleMember cmdlet can only be called from inside a module.
```

### Причина
Файлы `state.ps1` и `logging.ps1` содержали `Export-ModuleMember`, но загружались через `Import-Module` вместо dot-sourcing.

### Решение
1. **Убрали `Export-ModuleMember`** из `state.ps1` и `logging.ps1`
2. **Заменили `Import-Module` на dot-sourcing** в `windowsfix.ps1`:
   ```powershell
   # БЫЛО (неправильно):
   Import-Module (Join-Path $SrcRoot "internal\state.ps1") -Force
   Import-Module (Join-Path $SrcRoot "internal\logging.ps1") -Force
   
   # СТАЛО (правильно):
   . (Join-Path $SrcRoot "internal\state.ps1")
   . (Join-Path $SrcRoot "internal\logging.ps1")
   ```

3. **Разделили лог-файлы**:
   - `toolkit.log` - для функции `Write-Log` (наш логгер)
   - `transcript.log` - для `Start-Transcript` (PowerShell transcript)

## 📁 Исправленные файлы

1. **bin/windowsfix.ps1** - главный entrypoint (исправлен)
2. **src/internal/state.ps1** - управление состоянием (убран Export-ModuleMember)
3. **src/internal/logging.ps1** - логирование с retry (убран Export-ModuleMember)

## 🚀 Установка

### Вариант 1: Перезаписать файлы вручную
```bash
# Скопируйте файлы из архива в ваш проект:
cp fixed_files/bin/windowsfix.ps1 <ваш-проект>/bin/
cp fixed_files/src/internal/state.ps1 <ваш-проект>/src/internal/
cp fixed_files/src/internal/logging.ps1 <ваш-проект>/src/internal/
```

### Вариант 2: Использовать PowerShell
```powershell
# В корне проекта:
Copy-Item "fixed_files\bin\windowsfix.ps1" "bin\" -Force
Copy-Item "fixed_files\src\internal\state.ps1" "src\internal\" -Force
Copy-Item "fixed_files\src\internal\logging.ps1" "src\internal\" -Force
```

## ✅ Проверка

После замены файлов запустите:

```powershell
pwsh -ExecutionPolicy Bypass -NoProfile -File .\bin\windowsfix.ps1 -Mode SelfTest
```

### Ожидаемый результат:
```
SCRIPT_BUILD : WindowsFixToolkit v0.1.1-fixed
ScriptPath   : C:\Projects\WindowsFixToolkit\bin\windowsfix.ps1
PSVersion    : 7.4.0
IsAdmin      : False
OS Build     : 22631
OutputDir    : C:\Projects\WindowsFixToolkit\Outputs\WindowsFix_20260305_150000_SelfTest
LogPath      : C:\Projects\WindowsFixToolkit\Outputs\WindowsFix_20260305_150000_SelfTest\toolkit.log
TranscriptPath: C:\Projects\WindowsFixToolkit\Outputs\WindowsFix_20260305_150000_SelfTest\transcript.log

[2026-03-05 15:00:00] [INFO] ==============================================================================
[2026-03-05 15:00:00] [INFO]           Windows Fix Toolkit - SelfTest Mode
[2026-03-05 15:00:00] [INFO] ==============================================================================
[2026-03-05 15:00:00] [SUCCESS] Self-test completed!
[2026-03-05 15:00:00] [SUCCESS] Execution completed.
```

### Созданные файлы:
```
Outputs/WindowsFix_<timestamp>_SelfTest/
├── toolkit.log        ← Лог нашего приложения (Write-Log)
├── transcript.log     ← PowerShell transcript (Start-Transcript)
├── report.json        ← Отчёт в JSON (если генерируется)
└── report.md          ← Отчёт в Markdown (если генерируется)
```

## 📋 Структура лог-файлов

### toolkit.log
- Структурированный лог с цветными метками
- Записывается через `Write-Log` с retry-механизмом
- UTF-8 без BOM
- Защита от блокировки файла

Пример:
```
[2026-03-05 15:00:00] [INFO] Windows Fix Toolkit - SelfTest Mode
[2026-03-05 15:00:01] [SUCCESS]   ✓ PowerShell Version - OK
[2026-03-05 15:00:02] [SUCCESS]   ✓ Output directory writable - OK
```

### transcript.log
- Полный verbatim вывод PowerShell
- Создаётся через `Start-Transcript`
- Содержит всё: команды, stdout, stderr, debug

## 🐛 Troubleshooting

### Если скрипт всё ещё падает:

1. **Убедитесь, что заменили ВСЕ три файла**
2. **Очистите старые Outputs:**
   ```powershell
   Remove-Item ".\Outputs\*" -Recurse -Force
   ```
3. **Запустите с детальной диагностикой:**
   ```powershell
   pwsh -ExecutionPolicy Bypass -NoProfile -File .\bin\windowsfix.ps1 -Mode SelfTest -Verbose
   ```

### Если ошибка "file is being used by another process":
- Это исправлено: теперь `toolkit.log` и `transcript.log` - РАЗНЫЕ файлы
- Retry-механизм с 3 попытками записи
- Fallback на console при неудаче

## 📝 Changelog

### v0.1.1-fixed (2026-03-05)
- ✅ Исправлена ошибка "Export-ModuleMember can only be called from inside a module"
- ✅ Заменён Import-Module на dot-sourcing для internal скриптов
- ✅ Разделены toolkit.log и transcript.log
- ✅ Добавлен retry-механизм для записи в лог
- ✅ Улучшена обработка ошибок при логировании
- ✅ Добавлен встроенный SelfTest при отсутствии mode scripts

## 📞 Поддержка

Если возникают проблемы:
1. Проверьте версию PowerShell: `$PSVersionTable.PSVersion` (требуется >= 5.1)
2. Убедитесь, что файлы скопированы в правильные директории
3. Проверьте права на запись в директорию Outputs
4. Запустите с флагом -Verbose для детальной диагностики
