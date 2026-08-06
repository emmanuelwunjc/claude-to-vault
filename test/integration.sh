#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2012  # assertions are eval'd strings by design
# End-to-end test with a STUB claude CLI. No network, no tokens, no login.
# Covers the wiring the unit tests cannot: does a transcript actually become a
# correctly-named note with correct frontmatter, and does a failing CLI get
# caught instead of written to the vault?
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok(){ if eval "$1"; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }

sb="$(mktemp -d)"; trap 'rm -rf "$sb"' EXIT
mkdir -p "$sb/bin" "$sb/vault"

# A stub that behaves like `claude -p`: reads stdin, writes a summary.
cat > "$sb/bin/claude-ok" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '# proj (today)\n\n## Goal\nFix the thing.\n\n## Decisions\n- Did it the boring way.\n\n## Verified\n- Counts match.\n'
STUB
# A stub that fails the way a fresh install fails: one line, on stdout, exit 0.
cat > "$sb/bin/claude-noauth" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'Not logged in · Please run /login\n'
STUB
chmod +x "$sb/bin/claude-ok" "$sb/bin/claude-noauth"

t="$sb/transcript.jsonl"
printf '{"type":"user","cwd":"/Users/me/code/acme/sales_pipeline","message":"hi"}\n{"type":"assistant","message":"done"}\n{"type":"user","message":"thanks"}\n' > "$t"

run_hook() { # $1 = stub cli
  CTV_CONFIG=/dev/null CTV_VAULT_DIR="$sb/vault" CTV_CLAUDE_BIN="$1" \
  CTV_LOGFILE="$sb/state/run.log" CTV_WORKER=1 CTV_INPUT="$sb/event.json" \
    bash "$DIR/hooks/session-end.sh"
}
mk_event() { printf '{"transcript_path":"%s","session_id":"%s"}' "$t" "$1" > "$sb/event.json"; }

echo "Happy path:"
mk_event "11112222-3333-4444-5555-666677778888"
run_hook "$sb/bin/claude-ok"
note="$sb/vault/$(date +%Y-%m-%d)-sales_pipeline-11112222.md"
ok '[ -f "$note" ]'                                    "note written, named from transcript cwd and session id"
ok 'grep -q "^project: sales_pipeline\$" "$note"'    "frontmatter project is computed, not guessed"
ok 'grep -q "^session: 11112222-3333-4444-5555-666677778888\$" "$note"' "frontmatter carries the full session id"
ok 'grep -q "^## Decisions\$" "$note"'                 "model body is present under the frontmatter"
ok 'grep -q "WROTE" "$sb/state/run.log"'               "the write is logged"

echo "Same session again (RULE 5):"
before="$(ls -1 "$sb/vault" | wc -l | tr -d ' ')"
mk_event "11112222-3333-4444-5555-666677778888"   # the hook consumes its input file
run_hook "$sb/bin/claude-ok"
ok '[ "$(ls -1 "$sb/vault" | wc -l | tr -d " ")" = "$before" ]' "second run writes no duplicate note"
ok 'grep -q "SKIP already have a note" "$sb/state/run.log"'     "the skip is logged with a reason"

echo "CLI failing on stdout (RULE 2):"
mk_event "deadbeef-1111-2222-3333-444455556666"
run_hook "$sb/bin/claude-noauth"
ok '! ls "$sb/vault"/*-deadbeef.md >/dev/null 2>&1' "auth error is NOT written to the vault"
ok 'grep -q "SKIP error reply" "$sb/state/run.log"'  "the rejection is logged with a reason"

echo "Missing CLI:"
mk_event "aaaabbbb-1111-2222-3333-444455556666"
run_hook "$sb/bin/does-not-exist"; rc=$?
ok '[ "$rc" = "0" ]'                                     "hook still exits 0 (never blocks a session close)"
ok 'grep -q "ABORT claude CLI not found" "$sb/state/run.log"' "missing CLI is logged, not swallowed"

echo "Environment beats the config file:"
# The config uses `: "${VAR:=...}"` so an env var wins. A plain assignment there
# would silently override the environment, and a "sandbox" run aimed at a temp
# vault would write into the real one instead. That happened.
mkdir -p "$sb/cfg" "$sb/othervault"
printf ': "${CTV_VAULT_DIR:=%s/vault}"\n' "$sb" > "$sb/cfg/config.sh"
mk_event "cafe1234-1111-2222-3333-444455556666"
CTV_CONFIG="$sb/cfg/config.sh" CTV_VAULT_DIR="$sb/othervault" CTV_CLAUDE_BIN="$sb/bin/claude-ok" \
CTV_LOGFILE="$sb/state/run.log" CTV_WORKER=1 CTV_INPUT="$sb/event.json" \
  bash "$DIR/hooks/session-end.sh"
ok 'ls "$sb/othervault"/*-cafe1234.md >/dev/null 2>&1' "env CTV_VAULT_DIR overrides the config file"
ok '! ls "$sb/vault"/*-cafe1234.md >/dev/null 2>&1'    "config default did NOT capture the run"

echo "Noise is skipped:"
mkdir -p "$sb/proj"; cp "$t" "$sb/proj/agent-abcdef12.jsonl"
printf '{"transcript_path":"%s","session_id":"abcdef12-1111-2222-3333-444455556666"}' "$sb/proj/agent-abcdef12.jsonl" > "$sb/event.json"
run_hook "$sb/bin/claude-ok"
ok '! ls "$sb/vault"/*-abcdef12.md >/dev/null 2>&1' "subagent transcript produces no note"

echo "A write that fails must NOT report success:"
# Unchecked, the redirect fails but the log still says WROTE and the function
# returns 0. Rule 5 then dedups on a note that does not exist, so the next
# backfill pays for the same session again. Forever.
mkdir -p "$sb/ro"; chmod 500 "$sb/ro"
mk_event "beefbeef-1111-2222-3333-444455556666"
CTV_CONFIG=/dev/null CTV_VAULT_DIR="$sb/ro" CTV_CLAUDE_BIN="$sb/bin/claude-ok" \
CTV_LOGFILE="$sb/state/run.log" CTV_WORKER=1 CTV_INPUT="$sb/event.json" \
  bash "$DIR/hooks/session-end.sh"
ok '! grep -q "WROTE .*beefbeef" "$sb/state/run.log"' "read-only vault is not logged as a success"
ok 'grep -q "FAILED could not write" "$sb/state/run.log"' "the real reason is logged instead"
chmod 700 "$sb/ro"

echo "Blank session id is refused (would collide with every other blank one):"
printf '{"transcript_path":"%s","session_id":""}' "$t" > "$sb/event.json"
CTV_CONFIG=/dev/null CTV_VAULT_DIR="$sb/vault" CTV_CLAUDE_BIN="$sb/bin/claude-ok" \
CTV_LOGFILE="$sb/state/run.log" CTV_WORKER=1 CTV_INPUT="$sb/event.json" \
  bash "$DIR/hooks/session-end.sh"
ok '! ls "$sb/vault"/*--*.md >/dev/null 2>&1 && ! ls "$sb/vault"/*-.md >/dev/null 2>&1' \
   "no note written for a blank session id"
ok 'grep -q "ABORT SessionEnd carried no session_id" "$sb/state/run.log"' "blank session id is logged"

echo "ctv-backfill end to end (CI had zero coverage of it):"
mkdir -p "$sb/proj/-Users-me-code-demo" "$sb/bvault"
for i in 1 2 3; do
  printf '{"cwd":"/Users/me/code/demo"}\n{"a":2}\n{"a":3}\n' \
    > "$sb/proj/-Users-me-code-demo/0000000$i-aaaa-bbbb-cccc-dddddddddddd.jsonl"
done
printf '{"a":1}\n{"a":2}\n' > "$sb/proj/-Users-me-code-demo/agent-deadbeef.jsonl"
# A path long enough to trip BSD xargs' 255-byte -I replacement cap, which
# used to abort the whole run after announcing a larger count.
deep="$sb/proj/-Users-me-code-$(printf 'x%.0s' $(seq 1 200))"
mkdir -p "$deep"
printf '{"cwd":"/Users/me/code/deep"}\n{"a":2}\n{"a":3}\n' \
  > "$deep/00000009-aaaa-bbbb-cccc-dddddddddddd.jsonl"

bf() { CTV_CONFIG=/dev/null CTV_PROJECTS_DIR="$sb/proj" CTV_VAULT_DIR="$sb/bvault" \
       CTV_CLAUDE_BIN="$sb/bin/claude-ok" CTV_LOGFILE="$sb/state/run.log" \
       bash "$DIR/bin/ctv-backfill" "$@"; }

bf --dry-run > "$sb/dry.txt" 2>&1
ok 'grep -q "to distil         : 4" "$sb/dry.txt"' "dry run counts the 4 real sessions"
ok 'grep -q "skipped as noise  : 2" "$sb/dry.txt"' "dry run counts both subagent transcripts as noise"
ok '[ -z "$(ls -A "$sb/bvault")" ]'                "dry run wrote nothing"

bf --preview > "$sb/prev.txt" 2>&1
ok 'grep -q "^## Goal" "$sb/prev.txt"' "preview prints a real note"
ok '[ -z "$(ls -A "$sb/bvault")" ]'    "preview wrote nothing"

bf --limit 2 > "$sb/lim.txt" 2>&1
ok '[ "$(ls -1 "$sb/bvault" | wc -l | tr -d " ")" = "2" ]' "--limit 2 wrote exactly 2 notes"

bf > "$sb/full.txt" 2>&1
ok '[ "$(ls -1 "$sb/bvault" | wc -l | tr -d " ")" = "4" ]' "full run completes all 4, long path included"
ok '! grep -q "cannot be assembled" "$sb/full.txt"'        "no xargs replstr overflow on a 200+ char path"

bf > "$sb/again.txt" 2>&1
ok '! grep -q "^wrote " "$sb/again.txt"'                   "re-run is idempotent, distils nothing"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
