#!/usr/bin/env bash
# claude-to-vault installer. Writes a config file and wires the SessionEnd
# hook into ~/.claude/settings.json. Idempotent: re-running is safe.
#
#   ./install.sh --vault ~/obsidian/sessions
#   ./install.sh --vault ~/notes/sessions --model claude-haiku-4-5-20251001
#   ./install.sh --uninstall
set -euo pipefail

CTV_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-to-vault"
CONFIG="$CONFIG_DIR/config.sh"
HOOK="$CTV_HOME/hooks/session-end.sh"

VAULT=""; MODEL=""; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# The vault path is interpolated into `: "${CTV_VAULT_DIR:=HERE}"` in a file that
# is sourced by every session. Escape ONLY what is dangerous inside double
# quotes. printf '%q' is wrong here: it escapes spaces too, and those
# backslashes are literal inside the quotes, so "My Vault" became "My\ Vault"
# and every note went to a folder the user never sees.
qq() { printf '%s' "$1" | sed 's/[\\`"$]/\\&/g'; }

command -v python3 >/dev/null || { echo "python3 is required (used to edit settings.json safely)" >&2; exit 1; }

# --- settings.json surgery, in python because JSON is not a line format ------
# Adding or removing ONE hook entry while preserving everything else, including
# other people's hooks. Never rewrites the file wholesale.
edit_settings() {
  python3 - "$SETTINGS" "$HOOK" "$1" <<'PY'
import json, os, shutil, sys, tempfile
path, hook, action = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(f"{path} is not valid JSON ({e}); fix it before installing")

if not isinstance(data, dict):
    sys.exit(f"{path} must contain a JSON object, found {type(data).__name__}")

hooks = data.setdefault("hooks", {})
groups = hooks.setdefault("SessionEnd", [])

def has(entry):
    return any(h.get("command") == hook for h in entry.get("hooks", []))

if action == "add":
    if any(has(g) for g in groups):
        print("already wired")
    else:
        groups.append({"hooks": [{"type": "command", "command": hook}]})
        print("wired")
else:
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if h.get("command") != hook]
    hooks["SessionEnd"] = [g for g in groups if g.get("hooks")]
    if not hooks["SessionEnd"]:
        del hooks["SessionEnd"]
    if not hooks:
        del data["hooks"]
    print("unwired")

# Write to a temp file in the same directory, then rename. `open(path, "w")`
# truncates FIRST and writes second: a Ctrl-C, a full disk, or an OOM kill in
# that window leaves settings.json half-written and unparseable, destroying
# every model preference, permission rule, and MCP server the user had. Rename
# is atomic on both platforms this supports, so the file is never half-there.
if os.path.exists(path):
    shutil.copy2(path, path + ".ctv-backup")
d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
}

if [ "$UNINSTALL" = "1" ]; then
  if [ -f "$SETTINGS" ]; then edit_settings remove; else echo "no settings file at $SETTINGS"; fi
  echo "Config kept at $CONFIG (delete it by hand if you want it gone)."
  echo "Your notes were not touched."
  exit 0
fi

# --- vault path -------------------------------------------------------------
if [ -z "$VAULT" ]; then
  printf 'Where should session notes go? [%s/claude-vault/sessions] ' "$HOME"
  read -r VAULT </dev/tty || true
  VAULT="${VAULT:-$HOME/claude-vault/sessions}"
fi
VAULT="${VAULT/#\~/$HOME}"
mkdir -p "$VAULT"

# --- write config -----------------------------------------------------------
mkdir -p "$CONFIG_DIR"
# Never clobber a config someone has edited. Re-running the installer to
# rewire the hook must not silently drop a CTV_POST_WRITE line they added.
if [ -f "$CONFIG" ]; then
  cp "$CONFIG" "$CONFIG.bak"
  if grep -qE '^:[[:space:]]*"\$\{CTV_VAULT_DIR:=' "$CONFIG"; then
    python3 - "$CONFIG" "$(qq "$VAULT")" <<'PY'
import re, sys
path, vault = sys.argv[1], sys.argv[2]
s = open(path).read()
new = ': "${CTV_VAULT_DIR:=%s}"' % vault
s2, n = re.subn(r'^:\s*"\$\{CTV_VAULT_DIR:=.*$', new, s, count=1, flags=re.M)
if n == 0:                      # setting absent (only the comment mentions it)
    s2 = s.rstrip("\n") + "\n" + new + "\n"
open(path, "w").write(s2)
PY
    echo "kept your config, updated CTV_VAULT_DIR only (previous copy: $CONFIG.bak)"
  else
    # shellcheck disable=SC2016
    printf ': "${CTV_VAULT_DIR:=%s}"\n' "$(qq "$VAULT")" >> "$CONFIG"
    echo "appended CTV_VAULT_DIR to your existing config (previous copy: $CONFIG.bak)"
  fi
  CONFIG_WRITTEN=1
fi

[ "${CONFIG_WRITTEN:-0}" = "1" ] || {
  echo "# claude-to-vault config. Written by install.sh; edit freely."
  echo "#"
  echo "# Every line uses \`: \"\${VAR:=value}\"\`, which means 'default to this'."
  echo "# A plain VAR=value here would OVERRIDE the environment, so exporting"
  echo "# CTV_VAULT_DIR for a one-off run would silently do nothing. Keep the form."
  # shellcheck disable=SC2016
  printf ': "${CTV_VAULT_DIR:=%s}"\n' "$(qq "$VAULT")"
  # shellcheck disable=SC2016
  [ -n "$MODEL" ] && printf ': "${CTV_MODEL:=%s}"\n' "$(qq "$MODEL")"
  echo "# : \"\${CTV_MAX_BYTES:=240000}\"        # transcript bytes fed to the model"
  echo "# : \"\${CTV_POST_WRITE:=/path/to/index-note.sh}\"   # runs with the note path as \$1"
  echo "# : \"\${CTV_SKIP_PATTERNS:=claude-mem-observer}\"   # path fragments to ignore"
  echo "# : \"\${CTV_CLAUDE_BIN:=/full/path/to/claude}\"     # if claude is not on the hook's PATH"
} > "$CONFIG"

chmod +x "$HOOK" "$CTV_HOME/bin/ctv-backfill" "$CTV_HOME/test/selftest.sh" \
         "$CTV_HOME/test/integration.sh" 2>/dev/null || true

# --- wire the hook ----------------------------------------------------------
result="$(edit_settings add)"

echo
echo "claude-to-vault installed."
echo "  vault:    $VAULT"
echo "  config:   $CONFIG"
echo "  hook:     $HOOK ($result in $SETTINGS)"
echo "  log:      ${XDG_STATE_HOME:-$HOME/.local/state}/claude-to-vault/run.log"

# The wired hook path is absolute. Moving or deleting this clone stops the
# pipeline dead, and the only evidence is a line in a log nobody is watching.
echo
echo "This directory is now load-bearing: $CTV_HOME"
echo "Moving or deleting it stops notes from being written. Re-run install.sh after a move."

if ! command -v claude >/dev/null 2>&1; then
  echo
  echo "WARNING: no 'claude' on PATH. Nothing will be distilled until there is."
  echo "If it is installed elsewhere, add this to $CONFIG:"
  echo "  : \"\${CTV_CLAUDE_BIN:=/full/path/to/claude}\""
fi

echo
echo "See one note before trusting it with your vault:"
echo "  $CTV_HOME/bin/ctv-backfill --preview   # prints one note, writes nothing"
echo "Then distil past sessions:"
echo "  $CTV_HOME/bin/ctv-backfill --dry-run   # counts, no model calls"
echo "  $CTV_HOME/bin/ctv-backfill --limit 20  # start small"
