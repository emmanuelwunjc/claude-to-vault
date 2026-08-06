#!/usr/bin/env bash
# claude-to-vault: SessionEnd hook. Distils the session that just ended into
# one note in your vault. Wired into ~/.claude/settings.json by install.sh.
set -uo pipefail

# ---- Recursion guard -------------------------------------------------------
# The worker below calls `claude -p`. That headless run also ends and fires
# SessionEnd, re-running this hook. This env var (set on that call) makes the
# re-entry an immediate no-op, so the pipeline can never feed on itself.
[ "${CLAUDE_TO_VAULT:-}" = "1" ] && exit 0

# Resolve symlinks: without this, invoking through `ln -s` looks for lib/ next
# to the LINK, and the hook then fails writing nothing and logging nothing.
ctv_resolve_dir() {
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" && pwd
}
CTV_HOME="$(cd "$(ctv_resolve_dir "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- Entry mode: take stdin, relaunch detached, return instantly ------------
# Closing a session must never wait on a model call, so the work runs in a
# detached worker. Claude Code sees this hook exit immediately.
if [ -z "${CTV_WORKER:-}" ]; then
  tmp="$(mktemp -t claude-to-vault-XXXXXX)"
  cat > "$tmp"
  CTV_WORKER=1 CTV_INPUT="$tmp" nohup bash "$0" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  exit 0
fi

# ---- Worker mode -----------------------------------------------------------
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/vault-lib.sh
. "$CTV_HOME/lib/vault-lib.sh"

input="$(cat "$CTV_INPUT")"
rm -f "$CTV_INPUT"

parsed="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("\t".join([d.get("transcript_path", ""), d.get("session_id", "")]))
')" || { ctv_log "ABORT could not parse SessionEnd JSON (python3 missing, or schema changed)"; exit 0; }
IFS=$'\t' read -r transcript_path session_id <<< "$parsed"

[ -n "$session_id" ] || { ctv_log "ABORT SessionEnd carried no session_id"; exit 0; }
[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || { ctv_log "ABORT no transcript at '$transcript_path'"; exit 0; }
ctv_is_noise "$transcript_path" && { ctv_log "SKIP noise $transcript_path"; exit 0; }
ctv_has_content "$transcript_path" || { ctv_log "SKIP empty $transcript_path"; exit 0; }
command -v "$CTV_CLAUDE_BIN" >/dev/null 2>&1 || { ctv_log "ABORT claude CLI not found ($CTV_CLAUDE_BIN)"; exit 0; }
[ -f "$CTV_PROMPT" ] || { ctv_log "ABORT prompt template missing ($CTV_PROMPT)"; exit 0; }

mkdir -p "$CTV_VAULT_DIR"
ctv_write_note "$transcript_path" "$session_id" "$(date +%Y-%m-%d)" >/dev/null
exit 0
