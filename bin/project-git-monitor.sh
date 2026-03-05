#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MAIN_MENU_SCRIPT="$REPO_ROOT/bin/windowsfix-menu.sh"

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "[ERROR] Not a git repository: $REPO_ROOT"
  exit 1
fi

cd "$REPO_ROOT"

print_status() {
  local branch upstream ahead behind dirty
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo 'no-upstream')"

  if [[ "$upstream" != "no-upstream" ]]; then
    ahead="$(git rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
    behind="$(git rev-list --count "HEAD..${upstream}" 2>/dev/null || echo 0)"
  else
    ahead="0"
    behind="0"
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    dirty="yes"
  else
    dirty="no"
  fi

  cat <<STATUS
----------------------------------------
 Repo: $REPO_ROOT
 Branch: $branch
 Upstream: $upstream
 Ahead: $ahead | Behind: $behind
 Working tree dirty: $dirty
----------------------------------------
STATUS
}

cmd_pull() {
  echo "[INFO] Fetching remote updates..."
  git fetch --all --prune

  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"

  if [[ -z "${upstream:-}" ]]; then
    echo "[WARN] No upstream tracking branch configured for current branch."
    echo "[HINT] Configure with: git branch --set-upstream-to origin/$(git rev-parse --abbrev-ref HEAD)"
    return 0
  fi

  echo "[INFO] Pulling from $upstream ..."
  git pull --ff-only
  echo "[OK] Pull completed."
}

cmd_push() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "[WARN] Working tree has uncommitted changes."
    read -r -p "Create commit and push now? (y/N): " ans
    if [[ "${ans,,}" == "y" ]]; then
      git add -A
      read -r -p "Commit message: " msg
      if [[ -z "${msg:-}" ]]; then
        msg="chore: update local changes"
      fi
      git commit -m "$msg"
    else
      echo "[INFO] Push aborted: commit changes first."
      return 0
    fi
  fi

  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"

  if [[ -z "${upstream:-}" ]]; then
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    echo "[INFO] No upstream configured. Pushing and setting upstream to origin/$branch"
    git push -u origin "$branch"
  else
    git push
  fi

  echo "[OK] Push completed."
}

cleanup_menu() {
  while true; do
    clear || true
    print_status
    cat <<MENU
3) Решения очистки дерева (локально/удалённо)
  1. Local cleanup: restore tracked + clean untracked (опасно)
  2. Sync to remote (hard reset local to upstream, опасно)
  3. Force remote from local (push --force-with-lease, опасно)
  4. Stash local changes (безопаснее)
  0. Back
MENU

    read -r -p "Choose cleanup action: " action
    case "$action" in
      1)
        read -r -p "This will discard LOCAL uncommitted changes. Continue? (type YES): " c
        if [[ "$c" == "YES" ]]; then
          git restore --staged . || true
          git restore .
          git clean -fd
          echo "[OK] Local tracked/untracked changes cleaned."
        else
          echo "[INFO] Cancelled."
        fi
        read -r -p "Press Enter to continue..." _
        ;;
      2)
        local upstream
        upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
        if [[ -z "${upstream:-}" ]]; then
          echo "[WARN] No upstream configured."
        else
          read -r -p "This will HARD RESET local branch to $upstream. Continue? (type YES): " c
          if [[ "$c" == "YES" ]]; then
            git fetch --all --prune
            git reset --hard "$upstream"
            git clean -fd
            echo "[OK] Local branch synced to upstream."
          else
            echo "[INFO] Cancelled."
          fi
        fi
        read -r -p "Press Enter to continue..." _
        ;;
      3)
        read -r -p "This rewrites REMOTE history (force-with-lease). Continue? (type PUSH): " c
        if [[ "$c" == "PUSH" ]]; then
          local branch
          branch="$(git rev-parse --abbrev-ref HEAD)"
          git push --force-with-lease origin "$branch"
          echo "[OK] Remote updated from local with --force-with-lease."
        else
          echo "[INFO] Cancelled."
        fi
        read -r -p "Press Enter to continue..." _
        ;;
      4)
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"
        git stash push -u -m "project-git-monitor stash $ts" || true
        echo "[OK] Stash created (if there were changes)."
        read -r -p "Press Enter to continue..." _
        ;;
      0)
        return 0
        ;;
      *)
        echo "[WARN] Unknown option."
        read -r -p "Press Enter to continue..." _
        ;;
    esac
  done
}

run_main_menu() {
  if [[ -x "$MAIN_MENU_SCRIPT" ]]; then
    "$MAIN_MENU_SCRIPT"
  elif [[ -f "$MAIN_MENU_SCRIPT" ]]; then
    bash "$MAIN_MENU_SCRIPT"
  else
    echo "[WARN] Main menu script not found: $MAIN_MENU_SCRIPT"
  fi
}

main() {
  while true; do
    clear || true
    print_status
    cat <<MENU
Project Git Monitor
1) Пул (обновить локальный проект из Git)
2) Пуш (отправить локальные изменения в Git)
3) Решения для очистки дерева от ошибок (в обе стороны)
4) Запуск основного меню toolkit
0) Выход
MENU

    read -r -p "Выберите пункт: " choice
    case "$choice" in
      1)
        cmd_pull || true
        read -r -p "Press Enter to continue..." _
        ;;
      2)
        cmd_push || true
        read -r -p "Press Enter to continue..." _
        ;;
      3)
        cleanup_menu
        ;;
      4)
        run_main_menu || true
        read -r -p "Press Enter to continue..." _
        ;;
      0)
        echo "Bye."
        exit 0
        ;;
      *)
        echo "[WARN] Unknown option: $choice"
        read -r -p "Press Enter to continue..." _
        ;;
    esac
  done
}

main
