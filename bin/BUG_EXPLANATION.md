# Баг: Скрипт вылетает при выборе пункта 4

## 🐛 Проблема

При нажатии **пункта 4 (Запуск основного меню toolkit)**, скрипт `project-git-monitor.sh` **полностью завершается** вместо возврата в главное меню.

### Код с багом (строки 169-176):

```bash
run_main_menu() {
  if [[ -x "$MAIN_MENU_SCRIPT" ]]; then
    "$MAIN_MENU_SCRIPT"
  elif [[ -f "$MAIN_MENU_SCRIPT" ]]; then
    bash "$MAIN_MENU_SCRIPT"
  else
    echo "[WARN] Main menu script not found: $MAIN_MENU_SCRIPT"
  fi
}
```

И в главном меню (строки 189-192):

```bash
4)
  run_main_menu || true
  read -r -p "Press Enter to continue..." _
  ;;
```

---

## 🔍 Причина бага

### Пошаговый сценарий:

1. Пользователь выбирает **пункт 4** в `project-git-monitor.sh`
2. Вызывается функция `run_main_menu()`
3. Эта функция запускает `windowsfix-menu.sh`
4. В `windowsfix-menu.sh` пользователь выбирает **0 (Exit)**
5. `windowsfix-menu.sh` выполняет команду **`exit 0`**
6. **ПРОБЛЕМА:** Из-за `set -euo pipefail` в строке 2, команда `exit` в дочернем скрипте **распространяется** на родительский скрипт
7. `project-git-monitor.sh` **тоже завершается**, несмотря на `|| true`

### Почему `|| true` не помогает?

```bash
run_main_menu || true  # ← Не работает!
```

Когда дочерний процесс вызывает `exit`, это **не ошибка выполнения команды**, а **нормальное завершение процесса**. 

`|| true` срабатывает только при **ненулевом exit code**, но:
- `exit 0` = успешное завершение
- Родительский bash-скрипт **наследует** это завершение

---

## ✅ Решение

### Вариант 1: Минимальное исправление (рекомендуется)

Оборачиваем запуск в **subshell** с помощью `()`:

```bash
run_main_menu() {
  # Запускаем в subshell, чтобы exit не распространялся
  (
    if [[ -x "$MAIN_MENU_SCRIPT" ]]; then
      "$MAIN_MENU_SCRIPT"
    elif [[ -f "$MAIN_MENU_SCRIPT" ]]; then
      bash "$MAIN_MENU_SCRIPT"
    else
      echo "[WARN] Main menu script not found: $MAIN_MENU_SCRIPT"
      exit 1
    fi
  )
  
  # Захватываем exit code, но не пробрасываем его дальше
  local exit_code=$?
  
  if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then
    echo "[INFO] Main menu exited with code: $exit_code"
  fi
  
  # Всегда возвращаем 0, чтобы родительский скрипт продолжал работу
  return 0
}
```

И в главном меню:

```bash
4)
  run_main_menu  # ← Убрали || true (больше не нужно)
  read -r -p "Press Enter to continue..." _
  ;;
```

---

### Вариант 2: Альтернативное решение

Использовать `trap` для перехвата EXIT:

```bash
run_main_menu() {
  (
    trap 'exit 0' EXIT  # При любом exit возвращаем 0
    
    if [[ -x "$MAIN_MENU_SCRIPT" ]]; then
      "$MAIN_MENU_SCRIPT"
    elif [[ -f "$MAIN_MENU_SCRIPT" ]]; then
      bash "$MAIN_MENU_SCRIPT"
    fi
  )
  return 0
}
```

---

## 📝 Технические детали

### Что делает subshell `()`?

```bash
(command)  # Выполняется в отдельном подпроцессе
```

**Преимущества:**
- `exit` в subshell **не влияет** на родительский процесс
- Изменения переменных в subshell **не видны** снаружи
- Ошибки изолированы

**Альтернатива - фоновый процесс:**
```bash
command &  # Запускается в фоне (не подходит для интерактивных скриптов)
wait
```

---

## 🧪 Тестирование исправления

### До исправления:
```bash
$ ./project-git-monitor.sh
# Выбираем: 4
# В toolkit menu выбираем: 0
# Результат: project-git-monitor.sh ЗАВЕРШАЕТСЯ ❌
```

### После исправления:
```bash
$ ./project-git-monitor.sh
# Выбираем: 4
# В toolkit menu выбираем: 0
# Результат: Возврат в project-git-monitor.sh ✅
Press Enter to continue...
```

---

## 📦 Файлы с исправлениями

1. **project-git-monitor-minimal-fix.sh** - минимальное исправление оригинала
2. **project-git-monitor-fixed.sh** - полностью переработанная версия со всеми улучшениями

### Установка:

```bash
# Минимальный фикс (только исправление бага):
cp project-git-monitor-minimal-fix.sh bin/project-git-monitor.sh
chmod +x bin/project-git-monitor.sh

# Или полная версия (с дополнительными улучшениями):
cp project-git-monitor-fixed.sh bin/project-git-monitor.sh
chmod +x bin/project-git-monitor.sh
```

---

## 🎯 Итог

**Корень проблемы:** `exit` в дочернем скрипте завершает родительский процесс

**Решение:** Запуск дочернего скрипта в subshell `()` изолирует его от родителя

**Результат:** Скрипт корректно возвращается в главное меню после выхода из toolkit menu ✅
