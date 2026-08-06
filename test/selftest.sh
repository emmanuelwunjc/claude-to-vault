#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2012  # assertions are eval'd strings by design
# Self-test for THE FIVE RULES. No network, no model calls, no fixtures.
# Run after touching lib/vault-lib.sh:   ./test/selftest.sh
#
# Every case here exists because the corresponding bug shipped. If you are
# tempted to relax one, read the comment on the rule in lib/vault-lib.sh first.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTV_CONFIG=/dev/null . "$DIR/lib/vault-lib.sh"

pass=0; fail=0
ok(){ if eval "$1"; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '{"a":1}\n{"a":2}\n{"a":3}\n' > "$tmp/real.jsonl"
printf '{"a":1}\n'                   > "$tmp/tiny.jsonl"
printf 'You are distilling one Claude Code session into a single note.\ny\n' > "$tmp/meta.jsonl"
# A real session that READ or EDITED this pipeline. The prompt string appears,
# but not on line 1. Must survive.
printf '{"user":"fix the session hook"}\n{"tool":"You are distilling one Claude Code session into a single note."}\n' > "$tmp/about-hook.jsonl"
printf '{"a":1}\n{"a":2}\n' > "$tmp/agent-a0358e76.jsonl"
mkdir -p "$tmp/-Users-x--claude-mem-observer-sessions"
printf '{"a":1}\n{"a":2}\n' > "$tmp/-Users-x--claude-mem-observer-sessions/o.jsonl"

echo "RULE 4 (skip noise, but ONLY noise):"
ok 'ctv_is_noise "$tmp/-Users-x--claude-mem-observer-sessions/o.jsonl"' "configured skip pattern is noise"
ok 'ctv_is_noise "$tmp/meta.jsonl"'          "distillation meta-transcript is noise"
ok 'ctv_is_noise "$tmp/agent-a0358e76.jsonl"' "subagent transcript is noise"
ok '! ctv_is_noise "$tmp/real.jsonl"'        "real session is NOT noise"
ok '! ctv_is_noise "$tmp/about-hook.jsonl"'  "real session that mentions the prompt is NOT noise"

echo "RULE 1 (distil every real session; skip only the empty):"
ok 'ctv_has_content "$tmp/real.jsonl"'   "3-line transcript has content"
ok '! ctv_has_content "$tmp/tiny.jsonl"' "1-line transcript skipped"

echo "RULE 2 (never save an error as a note):"
ok 'ctv_is_bad_reply "Youve hit your session limit resets 2:40am"' "session-limit reply rejected"
ok 'ctv_is_bad_reply "usage limit reached"'                        "usage-limit reply rejected"
ok 'ctv_is_bad_reply "Prompt is too long · the request is ~792200 tokens (limit 200000)"' \
   "prompt-too-long reply rejected"
ok 'ctv_is_bad_reply "Not logged in · Please run /login"' "auth failure rejected (bites on fresh installs)"
ok 'ctv_is_bad_reply "Your credit balance is too low to access the API"' "billing failure rejected"
ok 'ctv_is_empty_reply "   "'            "blank reply rejected"
ok '! ctv_is_empty_reply "real"'         "non-empty reply accepted"
ok '! ctv_is_bad_reply "# proj
## Goal
A real summary."'                       "real summary accepted"
# The dangerous direction. A genuine note ABOUT a rate limit must survive.
_real_note="# session
## Goal
Debug the retry loop that swallowed the API error.
## Learnings
- The client hit 'rate limit exceeded' and the handler treated 'prompt is too long'
  as retryable, so it spun forever instead of failing fast.
## Produced
- A patch to the retry classifier and one regression test covering both strings.
- Follow-up notes on where else this pattern shows up across the codebase today."
ok '! ctv_is_bad_reply "$_real_note"' "real summary ABOUT rate limits is accepted"

echo "RULE 3 (never blow the model's context):"
head -c 600000 /dev/zero | tr '\0' 'x' > "$tmp/huge.jsonl"
CTV_MAX_BYTES=240000
ok '[ "$(ctv_feed_transcript "$tmp/huge.jsonl" | wc -c)" -le 240100 ]' "oversized transcript capped at the limit"
ok 'ctv_feed_transcript "$tmp/huge.jsonl" > "$tmp/fed.txt"; grep -q "TRUNCATED MIDDLE" "$tmp/fed.txt"' \
   "truncation is marked in the feed"
ok '[ "$(ctv_feed_transcript "$tmp/real.jsonl")" = "$(cat "$tmp/real.jsonl")" ]' "small transcript passed through intact"
# A non-numeric cap must fail CLOSED to the default, not disable truncation.
ok '( CTV_MAX_BYTES=1M; CTV_CONFIG=/dev/null . "$DIR/lib/vault-lib.sh"; [ "$(ctv_feed_transcript "$tmp/huge.jsonl" | wc -c)" -le 240100 ] )' \
   "non-numeric cap falls back to default, still truncates"

echo "RULE 5 (one session, one note):"
mkdir -p "$tmp/-Users-me-code-acme-sales-pipeline" "$tmp/notes"
pt="$tmp/-Users-me-code-acme-sales-pipeline/11112222-3333-4444-5555-666677778888.jsonl"
printf '{"type":"user","cwd":"/Users/me/code/acme/sales_pipeline","message":"hi"}\n{"a":2}\n' > "$pt"
# The encoded directory says "tracking". The transcript says "sales_pipeline".
ok '[ "$(ctv_project_for "$pt")" = "sales_pipeline" ]' "project read from transcript cwd, not the lossy dir name"
printf 'x\n' > "$tmp/notes/2026-08-05-code-11112222.md"
ok 'ctv_note_exists "$tmp/notes" "11112222"'  "existing note found despite a different project in the filename"
ok '! ctv_note_exists "$tmp/notes" "deadbeef"' "absent session reports no note"
printf '{"a":1}\n{"a":2}\n' > "$tmp/nocwd.jsonl"
ok '[ -n "$(ctv_project_for "$tmp/nocwd.jsonl")" ]' "transcript with no cwd still yields a project name"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
