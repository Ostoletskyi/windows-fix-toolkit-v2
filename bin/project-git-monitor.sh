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

# ---------- helpers ----------
pause() { read -r -p "Press Enter to continue..." _; }

clear_screen() {
  if command -v clear >/dev/null 2>&1; then
    clear || true
  else
    # ANSI fallback
    printf '\033[2J\033[H' || true
  fi
}

trim() {
  # trim leading/trailing whitespace
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

current_upstream() {
  # prints upstream ref or empty string if none
  git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true
}

is_dirty() {
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

git_try_fetch() {
  echo "[INFO] Fetching remote updates..."
  if ! git fetch --all --prune; then
    echo "[ERROR] git fetch failed (network/auth issue?)."
    echo "[HINT] Check: network, VPN/proxy, GitHub access, credentials."
    return 1
  fi
  return 0
}

print_status() {
  local branch upstream ahead behind dirty
  branch="$(current_branch)"
  upstream="$(current_upstream)"
  [[ -z "${upstream:-}" ]] && upstream="no-upstream"

  if [[ "$upstream" != "no-upstream" ]]; then
    ahead="$(git rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
    behind="$(git rev-list --count "HEAD..${upstream}" 2>/dev/null || echo 0)"
  else
    ahead="0"
    behind="0"
  fi

  dirty="no"
  is_dirty && dirty="yes"

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

# ---------- commands ----------
cmd_pull() {
  # Do not die on fetch/pull errors under set -e
  set +e
  git_try_fetch
  local fetch_ec=$?
  set -e
  if [[ $fetch_ec -ne 0 ]]; then
    echo "[WARN] Pull not performed because fetch failed."
    return 0
  fi

  local upstream branch
  branch="$(current_branch)"
  upstream="$(current_upstream)"

  if [[ -z "${upstream:-}" ]]; then
    echo "[WARN] No upstream tracking branch configured for '$branch'."
    echo "[WHAT THIS MEANS] You cannot pull automatically because git doesn't know remote branch."
    echo "[FIX] Run:"
    echo "  git branch --set-upstream-to origin/$branch $branch"
    echo
    echo "[INFO] No changes pulled."
    return 0
  fi

  echo "[INFO] Pulling from $upstream (fast-forward only)..."

  set +e
  git pull --ff-only
  local pull_ec=$?
  set -e

  if [[ $pull_ec -eq 0 ]]; then
    echo "[OK] Pull completed (fast-forward)."
    return 0
  fi

  echo "[WARN] Fast-forward not possible (branches diverged) OR pull failed."
  echo "Choose how to proceed:"
  cat <<'PULLMENU'
  1) Rebase (git pull --rebase)          [recommended for clean history]
  2) Merge  (git pull --no-rebase)       [creates merge commit]
  3) Abort / back to menu
PULLMENU

  read -r -p "Select [1-3]: " choice
  case "${choice:-}" in
    1)
      set +e
      git pull --rebase
      local ec=$?
      set -e
      if [[ $ec -eq 0 ]]; then
        echo "[OK] Rebase pull completed."
      else
        echo "[ERROR] Rebase failed."
        echo "[HINT] You may need to resolve conflicts, then run:"
        echo "  git rebase --continue"
        echo "or to abort:"
        echo "  git rebase --abort"
      fi
      ;;
    2)
      set +e
      git pull --no-rebase
      local ec=$?
      set -e
      if [[ $ec -eq 0 ]]; then
        echo "[OK] Merge pull completed."
      else
        echo "[ERROR] Merge pull failed."
        echo "[HINT] You may need to resolve conflicts, then commit the merge."
      fi
      ;;
    *)
      echo "[INFO] Pull aborted."
      ;;
  esac

  return 0
}

cmd_push() {
  local branch upstream

  branch="$(current_branch)"

  if is_dirty; then
    echo "[WARN] Working tree has uncommitted changes."
    read -r -p "Create commit and push now? (y/N): " ans
    if [[ "${ans,,}" == "y" ]]; then
      echo "[INFO] Staging changes..."
      set +e
      git add -A
      local add_ec=$?
      set -e
      if [[ $add_ec -ne 0 ]]; then
        echo "[ERROR] git add failed. Fix the issue and try again."
        return 0
      fi

      read -r -p "Commit message: " msg
      msg="$(trim "${msg:-}")"
      if [[ -z "$msg" ]]; then
        msg="chore: update local changes"
      fi

      echo "[INFO] Creating commit..."
      set +e
      git commit -m "$msg"
      local commit_ec=$?
      set -e

      if [[ $commit_ec -ne 0 ]]; then
        echo "[WARN] git commit did not succeed."
        echo "[HINT] Common reason: nothing to commit (empty commit)."
        # Re-check dirty status after failed commit attempt
        if is_dirty; then
          echo "[WARN] Still dirty after commit attempt. Push will NOT proceed."
          return 0
        fi
        echo "[INFO] Tree is clean. Continuing to push."
      fi

    else
      echo "[INFO] Push aborted: commit changes first."
      return 0
    fi
  fi

  # After potential commit attempt, verify clean state
  if is_dirty; then
    echo "[WARN] Working tree is still dirty. Refusing to push."
    echo "[HINT] Commit or stash your changes first."
    return 0
  fi

  upstream="$(current_upstream)"
  if [[ -z "${upstream:-}" ]]; then
    echo "[INFO] No upstream configured for '$branch'. Pushing and setting upstream to origin/$branch"
    set +e
    git push -u origin "$branch"
    local ec=$?
    set -e
    if [[ $ec -ne 0 ]]; then
      echo "[ERROR] Push failed. Check authentication / permissions."
      return 0
    fi
  else
    set +e
    git push
    local ec=$?
    set -e
    if [[ $ec -ne 0 ]]; then
      echo "[ERROR] Push failed."
      echo "[HINT] You may need to pull/rebase first."
      return 0
    fi
  fi

  echo "[OK] Push completed."
  return 0
}

preview_clean() {
  echo "[INFO] Preview of untracked files/dirs that would be removed:"
  # -n dry-run
  set +e
  git clean -fdn
  local ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    echo "[WARN] Could not preview clean. git clean -fdn failed."
  fi
}

cleanup_menu() {
  while true; do
    clear_screen
    print_status
    cat <<'MENU'
3) Решения очистки дерева (локально/удалённо)
  1. Local cleanup: restore tracked + clean untracked (опасно)
  2. Sync to remote (hard reset local to upstream, опасно)
  3. Force remote from local (push --force-with-lease, опасно)
  4. Stash local changes (безопаснее)
  0. Back
MENU

    read -r -p "Choose cleanup action: " action
    case "${action:-}" in
      1)
        preview_clean
        read -r -p "This will discard LOCAL uncommitted changes AND delete untracked files. Continue? (type YES): " c
        if [[ "$c" == "YES" ]]; then
          git restore --staged . || true
          git restore . || true
          git clean -fd
          echo "[OK] Local tracked/untracked changes cleaned."
        else
          echo "[INFO] Cancelled."
        fi
        pause
        ;;
      2)
        local upstream
        upstream="$(current_upstream)"
        if [[ -z "${upstream:-}" ]]; then
          echo "[WARN] No upstream configured for current branch."
          echo "[FIX] Set upstream then retry:"
          echo "  git branch --set-upstream-to origin/$(current_branch) $(current_branch)"
          pause
        else
          read -r -p "This will HARD RESET local branch to $upstream and delete untracked files. Continue? (type YES): " c
          if [[ "$c" == "YES" ]]; then
            set +e
            git_try_fetch
            local ec=$?
            set -e
            if [[ $ec -ne 0 ]]; then
              echo "[WARN] Cannot sync because fetch failed."
              pause
              continue
            fi

            preview_clean
            git reset --hard "$upstream"
            git clean -fd
            echo "[OK] Local branch synced to upstream."
            pause
          else
            echo "[INFO] Cancelled."
            pause
          fi
        fi
        ;;
      3)
        read -r -p "This rewrites REMOTE history (force-with-lease). Continue? (type PUSH): " c
        if [[ "$c" == "PUSH" ]]; then
          local branch
          branch="$(current_branch)"
          set +e
          git push --force-with-lease origin "$branch"
          local ec=$?
          set -e
          if [[ $ec -eq 0 ]]; then
            echo "[OK] Remote updated from local with --force-with-lease."
          else
            echo "[ERROR] Force push failed."
          fi
        else
          echo "[INFO] Cancelled."
        fi
        pause
        ;;
      4)
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"

        # Show status so user knows what will be stashed
        if ! is_dirty; then
          echo "[INFO] Nothing to stash (working tree clean)."
          pause
          continue
        fi

        set +e
        git stash push -u -m "project-git-monitor stash $ts"
        local ec=$?
        set -e
        if [[ $ec -eq 0 ]]; then
          echo "[OK] Stash created."
        else
          echo "[ERROR] git stash failed."
          echo "[HINT] Check for repository issues, locked index, or file permission problems."
        fi
        pause
        ;;
      0)
        return 0
        ;;
      *)
        echo "[WARN] Unknown option."
        pause
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
    pause
  fi
}

main() {
  while true; do
    clear_screen
    print_status
    cat <<'MENU'
Project Git Monitor
1) Пул (обновить локальный проект из Git)
2) Пуш (отправить локальные изменения в Git)
3) Решения для очистки дерева от ошибок (в обе стороны)
4) Запуск основного меню toolkit
0) Выход
MENU

    read -r -p "Выберите пункт: " choice
    case "${choice:-}" in
      1) cmd_pull || true; pause ;;
      2) cmd_push || true; pause ;;
      3) cleanup_menu ;;
      4) run_main_menu ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "[WARN] Unknown option: $choice"; pause ;;
    esac
  done
}

main