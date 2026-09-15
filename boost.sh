#!/bin/bash
# boost.sh — free up RAM and CPU on macOS by quitting apps and dropping caches.
# Usage: boost.sh [--dry-run] [--force] [--no-purge] [--quiet] [--pause] [--resume]

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_FILE="$DIR/keep.txt"
EXTRAS_FILE="$DIR/extras.txt"
LOG="$DIR/boost.log"
SHARED_KEEP="$HOME/Library/Application Support/Boost/keep.txt"   # written by Boost.app

DRY_RUN=0; FORCE=0; DO_PURGE=1; QUIET=0; MODE=close
QUIT_TIMEOUT=6          # seconds to wait for a graceful quit before giving up

for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --force)    FORCE=1 ;;
    --no-purge) DO_PURGE=0 ;;
    --quiet)    QUIET=1 ;;
    --pause)    MODE=pause ;;
    --resume)   MODE=resume ;;
    -h|--help)
      sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---------- memory reporting ----------

page_size() { vm_stat | sed -n '1s/.*page size of \([0-9]*\).*/\1/p'; }

# Prints: available_gb pressure_pct swap_used_mb
mem_snapshot() {
  local ps pages_free pages_inactive pages_spec pages_purge avail pressure swap
  ps=$(page_size)
  pages_free=$(vm_stat | awk '/Pages free/            {gsub(/\./,"",$3); print $3}')
  pages_inactive=$(vm_stat | awk '/Pages inactive/    {gsub(/\./,"",$3); print $3}')
  pages_spec=$(vm_stat | awk '/Pages speculative/     {gsub(/\./,"",$3); print $3}')
  pages_purge=$(vm_stat | awk '/Pages purgeable/      {gsub(/\./,"",$3); print $3}')
  avail=$(( (pages_free + pages_inactive + pages_spec + pages_purge) * ps ))
  pressure=$(memory_pressure 2>/dev/null | awk '/free percentage/ {gsub(/%/,"",$NF); print $NF}')
  swap=$(sysctl -n vm.swapusage | awk '{gsub(/M/,"",$6); print $6}')
  printf '%.2f %s %s\n' "$(echo "$avail" | awk '{print $1/1073741824}')" "${pressure:-?}" "${swap:-0}"
}

# ---------- which apps to leave alone ----------

# Walk the parent-process chain and keep whatever app launched us,
# so Boost never quits its own terminal / launcher out from under itself.
ancestor_apps() {
  local pid=$$ exe name
  while [ "$pid" -gt 1 ]; do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
    # Every .app in the path, so a helper protects its parent app too.
    printf '%s\n' "$exe" | grep -oE '/[^/]+\.app/' | sed -e 's|^/||' -e 's|\.app/$||'
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done
}

read_list() {  # strip comments and blank lines
  [ -f "$1" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$1" | grep -v '^$'
}

read_shared_keep() {   # "<bundle id>\t<name>" -> name
  [ -f "$SHARED_KEEP" ] || return 0
  sed -e 's/#.*//' "$SHARED_KEEP" | awk -F'\t' 'NF>1 && $2 != "" {print $2}'
}

KEEP=$'Finder\nBoost\n'"$(read_list "$KEEP_FILE")"$'\n'"$(read_shared_keep)"$'\n'"$(ancestor_apps)"

is_kept() {
  local candidate="$1" k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    [ "$k" = "$candidate" ] && return 0
  done <<< "$KEEP"
  return 1
}

# Escape a string for safe embedding inside an AppleScript double-quoted literal.
as_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Every pid in the process tree rooted at $1, $1 included.
subtree_pids() {
  ps -Ao pid=,ppid= | awk -v root="$1" '
    { pid[NR]=$1; par[NR]=$2; n=NR }
    END {
      keep[root]=1; changed=1
      while (changed) {
        changed=0
        for (i=1; i<=n; i++)
          if ((par[i] in keep) && !(pid[i] in keep)) { keep[pid[i]]=1; changed=1 }
      }
      for (p in keep) print p
    }'
}

app_pid() {
  osascript -e "tell application \"System Events\" to get unix id of process \"$(as_escape "$1")\"" 2>/dev/null
}

running_apps() {
  osascript -e 'tell application "System Events" to get name of every process whose background only is false' 2>/dev/null \
    | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' | grep -v '^$'
}

still_running() { osascript -e "tell application \"System Events\" to (name of processes) contains \"$(as_escape "$1")\"" 2>/dev/null; }

# ---------- do the work ----------

exec 3>&1                      # fd 3 = the human-readable report
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&3; }

if [ "$MODE" = resume ]; then
  woken=0
  while read -r pid; do
    [ -n "$pid" ] && kill -CONT "$pid" 2>/dev/null && woken=$((woken + 1))
  done < <(ps -Ao pid=,stat= | awk '$2 ~ /^T/ {print $1}')
  say "Resumed $woken paused process(es)."
  exit 0
fi

read -r BEFORE_AVAIL BEFORE_PRESSURE BEFORE_SWAP <<< "$(mem_snapshot)"

QUIT=(); REFUSED=(); SKIPPED=()

while IFS= read -r app; do
  if is_kept "$app"; then SKIPPED+=("$app"); continue; fi

  if [ "$DRY_RUN" = 1 ]; then QUIT+=("$app"); continue; fi

  if [ "$MODE" = pause ]; then
    # Freeze the app and every descendant: zero CPU, state preserved.
    root=$(app_pid "$app")
    if [ -n "$root" ]; then
      while read -r pid; do
        [ -n "$pid" ] && kill -STOP "$pid" 2>/dev/null
      done < <(subtree_pids "$root")
      QUIT+=("$app")
    fi
    continue
  fi

  # Graceful quit first: apps with unsaved work get to put up their save sheet.
  osascript -e "tell application \"$(as_escape "$app")\" to quit" >/dev/null 2>&1 &
  quit_pid=$!
  for _ in $(seq 1 $((QUIT_TIMEOUT * 4))); do
    kill -0 "$quit_pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -9 "$quit_pid" 2>/dev/null

  if [ "$(still_running "$app")" = "true" ]; then
    if [ "$FORCE" = 1 ]; then
      pkill -x "$app" 2>/dev/null; sleep 0.5
      pkill -9 -x "$app" 2>/dev/null
      QUIT+=("$app (forced)")
    else
      REFUSED+=("$app")
    fi
  else
    QUIT+=("$app")
  fi
done < <(running_apps)

# Background helpers / menu-bar agents listed in extras.txt
EXTRAS_KILLED=()
while IFS= read -r proc; do
  [ -z "$proc" ] && continue
  [ "$MODE" = pause ] && continue
  # Exact process-name match first. If that misses — which happens when the
  # process name has non-ASCII characters, or differs from the bundle name —
  # fall back to matching the app bundle path, which is still unambiguous.
  if pgrep -x "$proc" >/dev/null 2>&1; then
    matcher=(-x "$proc")
  elif pgrep -f "/${proc}.app/" >/dev/null 2>&1; then
    matcher=(-f "/${proc}.app/")
  else
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then EXTRAS_KILLED+=("$proc"); continue; fi
  pkill "${matcher[@]}" 2>/dev/null; sleep 0.3; pkill -9 "${matcher[@]}" 2>/dev/null
  EXTRAS_KILLED+=("$proc")
done < <(read_list "$EXTRAS_FILE")

# Drop the filesystem cache. Needs root, so this pops the standard macOS auth dialog.
PURGE_STATUS="skipped"
if [ "$DO_PURGE" = 1 ] && [ "$DRY_RUN" = 0 ] && [ "$MODE" = close ]; then
  if sudo -n /usr/sbin/purge 2>/dev/null; then
    PURGE_STATUS="done"
  elif osascript -e 'do shell script "/usr/sbin/purge" with administrator privileges' >/dev/null 2>&1; then
    PURGE_STATUS="done"
  else
    PURGE_STATUS="declined"
  fi
fi

sleep 1
read -r AFTER_AVAIL AFTER_PRESSURE AFTER_SWAP <<< "$(mem_snapshot)"
FREED=$(awk -v a="$AFTER_AVAIL" -v b="$BEFORE_AVAIL" 'BEGIN{printf "%+.2f", a-b}')

# ---------- report ----------

[ "$DRY_RUN" = 1 ] && say "DRY RUN — nothing was actually quit." && say ""

if [ ${#QUIT[@]} -gt 0 ]; then
  say "$([ "$MODE" = pause ] && echo Paused || echo Closed) (${#QUIT[@]}): $(printf '%s, ' "${QUIT[@]}" | sed 's/, $//')"
else
  say "Closed: nothing — everything running was on the keep list."
fi
[ ${#EXTRAS_KILLED[@]} -gt 0 ] && say "Helpers killed: $(printf '%s, ' "${EXTRAS_KILLED[@]}" | sed 's/, $//')"
[ ${#REFUSED[@]} -gt 0 ]       && say "Still open (unsaved work? quit manually): $(printf '%s, ' "${REFUSED[@]}" | sed 's/, $//')"
say ""
say "RAM available:   ${BEFORE_AVAIL} GB  ->  ${AFTER_AVAIL} GB   (${FREED} GB)"
say "Memory free:     ${BEFORE_PRESSURE}%  ->  ${AFTER_PRESSURE}%"
say "Swap used:       ${BEFORE_SWAP} MB  ->  ${AFTER_SWAP} MB"
say "Cache purge:     ${PURGE_STATUS}"

if [ "$DRY_RUN" = 0 ]; then
  printf '%s | freed %s GB | closed %d | purge %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$FREED" "${#QUIT[@]}" "$PURGE_STATUS" >> "$LOG"
fi
