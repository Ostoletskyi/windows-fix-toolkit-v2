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

#------------------------------------------------------------------------------
# Utilities
#------------------------------------------------------------------------------
safe_clear() {
  clear 2>/dev/null || printf '\033[2J\033[H'
}

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

#------------------------------------------------------------------------------
# Command: Pull
#------------------------------------------------------------------------------
cmd_pull() {
  echo "[INFO] Fetching remote updates..."
  
  # FIX: Handle fetch errors gracefully
  if ! git fetch --all --prune; then
    echo "[ERROR] Failed to fetch from remote. Check network connection."
    return 1
  fi

  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"

  if [[ -z "${upstream:-}" ]]; then
    echo "[WARN] No upstream tracking branch configured for current branch."
    echo "[HINT] Configure with: git branch --set-upstream-to origin/$(git rev-parse --abbrev-ref HEAD)"
    echo "[INFO] Pull aborted - no upstream configured."
    return 1
  fi

  echo "[INFO] Pulling from $upstream ..."
  
  # FIX: Handle non-fast-forward scenarios
  if ! git pull --ff-only; then
    echo ""
    echo "[ERROR] Fast-forward pull failed (local and remote have diverged)."
    echo ""
    echo "Options:"
    echo "  1. Rebase: git pull --rebase"
    echo "  2. Merge:  git pull --no-ff"
    echo "  3. Reset:  Use cleanup menu option 2"
    echo ""
    read -r -p "Attempt rebase now? (y/N): " ans
    if [[ "${ans,,}" == "y" ]]; then
      if git pull --rebase; then
        echo "[OK] Rebase successful."
      else
        echo "[ERROR] Rebase failed. Resolve conflicts manually."
        return 1
      fi
    else
      echo "[INFO] Pull aborted. Resolve manually."
      return 1
    fi
  fi
  
  echo "[OK] Pull completed."
}

#------------------------------------------------------------------------------
# Command: Push
#------------------------------------------------------------------------------
cmd_push() {
  # FIX: Check for changes BEFORE prompting
  local has_changes=false
  if [[ -n "$(git status --porcelain)" ]]; then
    has_changes=true
  fi

  if [[ "$has_changes" == "true" ]]; then
    echo "[WARN] Working tree has uncommitted changes."
    read -r -p "Create commit and push now? (y/N): " ans
    if [[ "${ans,,}" == "y" ]]; then
      # FIX: Handle git add errors
      if ! git add -A; then
        echo "[ERROR] Failed to stage changes."
        return 1
      fi
      
      # FIX: Validate commit message
      local msg=""
      while [[ -z "${msg// /}" ]]; do  # Remove spaces for validation
        read -r -p "Commit message: " msg
        if [[ -z "${msg// /}" ]]; then
          echo "[WARN] Commit message cannot be empty or only whitespace."
          read -r -p "Use default message 'chore: update local changes'? (y/N): " use_default
          if [[ "${use_default,,}" == "y" ]]; then
            msg="chore: update local changes"
            break
          fi
        fi
      done
      
      # FIX: Check if there's actually something to commit
      if git diff --cached --quiet; then
        echo "[WARN] No changes to commit (all changes may be in .gitignore)."
        return 1
      fi
      
      # FIX: Handle commit errors
      if ! git commit -m "$msg"; then
        echo "[ERROR] Commit failed."
        return 1
      fi
      
      echo "[OK] Commit created: $msg"
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
    
    # FIX: Handle push errors
    if ! git push -u origin "$branch"; then
      echo "[ERROR] Failed to push to origin/$branch."
      return 1
    fi
  else
    # FIX: Handle push errors
    if ! git push; then
      echo "[ERROR] Push failed. You may need to pull first or use force push."
      return 1
    fi
  fi

  echo "[OK] Push completed."
}

#------------------------------------------------------------------------------
# Cleanup Menu
#------------------------------------------------------------------------------
cleanup_menu() {
  while true; do
    safe_clear
    print_status
    cat <<MENU
╔════════════════════════════════════════════════════════════════╗
║  3) Решения очистки дерева (локально/удалённо)                 ║
╚════════════════════════════════════════════════════════════════╝
  1. Local cleanup: restore tracked + clean untracked (ОПАСНО!)
  2. Sync to remote (hard reset local to upstream, ОПАСНО!)
  3. Force remote from local (push --force-with-lease, ОПАСНО!)
  4. Stash local changes (безопаснее)
  0. Back
MENU

    read -r -p "Choose cleanup action: " action
    case "$action" in
      1)
        echo ""
        echo "⚠️  WARNING: This will PERMANENTLY DELETE:"
        echo "   - All uncommitted changes in tracked files"
        echo "   - All untracked files and directories"
        echo ""
        
        # FIX: Show what will be deleted
        echo "Files that will be removed:"
        git status --porcelain | head -20
        local file_count
        file_count="$(git status --porcelain | wc -l)"
        if [[ "$file_count" -gt 20 ]]; then
          echo "... and $((file_count - 20)) more files"
        fi
        echo ""
        
        read -r -p "Type 'DELETE' to proceed: " c
        if [[ "$c" == "DELETE" ]]; then
          git restore --staged . 2>/dev/null || true
          git restore . 2>/dev/null || true
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
          echo "[WARN] No upstream configured. Cannot sync."
          read -r -p "Press Enter to continue..." _
        else
          echo ""
          echo "⚠️  WARNING: This will HARD RESET your local branch to $upstream"
          echo "   All local commits and changes will be LOST!"
          echo ""
          
          read -r -p "Type 'RESET' to proceed: " c
          if [[ "$c" == "RESET" ]]; then
            if ! git fetch --all --prune; then
              echo "[ERROR] Failed to fetch updates."
              read -r -p "Press Enter to continue..." _
              continue
            fi
            
            git reset --hard "$upstream"
            git clean -fd
            echo "[OK] Local branch synced to upstream."
          else
            echo "[INFO] Cancelled."
          fi
          read -r -p "Press Enter to continue..." _
        fi
        ;;
      
      3)
        echo ""
        echo "⚠️  DANGER: This rewrites REMOTE history!"
        echo "   Other collaborators may have conflicts."
        echo "   Only use if you know what you're doing."
        echo ""
        
        read -r -p "Type 'FORCE-PUSH' to proceed: " c
        if [[ "$c" == "FORCE-PUSH" ]]; then
          local branch
          branch="$(git rev-parse --abbrev-ref HEAD)"
          
          if git push --force-with-lease origin "$branch"; then
            echo "[OK] Remote updated from local with --force-with-lease."
          else
            echo "[ERROR] Force push failed (remote may have new commits)."
          fi
        else
          echo "[INFO] Cancelled."
        fi
        read -r -p "Press Enter to continue..." _
        ;;
      
      4)
        echo "[INFO] Creating stash..."
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"
        
        # FIX: Properly handle stash errors
        if git stash push -u -m "project-git-monitor stash $ts"; then
          echo "[OK] Stash created: project-git-monitor stash $ts"
          echo "[INFO] Restore with: git stash pop"
        else
          local stash_exit=$?
          if [[ $stash_exit -eq 1 ]]; then
            echo "[INFO] No local changes to stash."
          else
            echo "[ERROR] Failed to create stash (exit code: $stash_exit)."
          fi
        fi
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

#------------------------------------------------------------------------------
# Run Main Menu
#------------------------------------------------------------------------------
run_main_menu() {
  if [[ -x "$MAIN_MENU_SCRIPT" ]]; then
    "$MAIN_MENU_SCRIPT"
  elif [[ -f "$MAIN_MENU_SCRIPT" ]]; then
    bash "$MAIN_MENU_SCRIPT"
  else
    echo "[WARN] Main menu script not found: $MAIN_MENU_SCRIPT"
    read -r -p "Press Enter to continue..." _
  fi
}

#------------------------------------------------------------------------------
# Main Menu
#------------------------------------------------------------------------------
main() {
  while true; do
    safe_clear
    print_status
    cat <<MENU
╔════════════════════════════════════════════════════════════════╗
║              Project Git Monitor                               ║
╚════════════════════════════════════════════════════════════════╝
1) Пул (обновить локальный проект из Git)
2) Пуш (отправить локальные изменения в Git)
3) Решения для очистки дерева от ошибок (в обе стороны)
4) Запуск основного меню toolkit
0) Выход
────────────────────────────────────────────────────────────────
MENU

    read -r -p "Выберите пункт: " choice
    case "$choice" in
      1)
        cmd_pull || echo "[WARN] Pull operation failed or incomplete."
        read -r -p "Press Enter to continue..." _
        ;;
      2)
        cmd_push || echo "[WARN] Push operation failed or incomplete."
        read -r -p "Press Enter to continue..." _
        ;;
      3)
        cleanup_menu
        ;;
      4)
        run_main_menu
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