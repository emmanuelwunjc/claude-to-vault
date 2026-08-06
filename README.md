# claude-to-vault

Every Claude Code session ends. This writes down what it was worth: the goal, the decisions and why, what you learned, what shipped, what is still open. One markdown note per session.

Notes land in a folder you choose, with YAML frontmatter, so Obsidian and `grep` can both find them. One `claude -p` call per session on a cheap model, billed to the plan you already have. Your transcript goes to that model and nowhere else.

Four bash files and a prompt. No daemon, no database. The hard part is not writing notes, it is not writing bad ones: a failed model call is never saved as a summary, one session never becomes two notes, and every skip writes one line to a log saying why.

## Your data

Worth knowing before you install, because the tool reads your terminal history.

- **What is sent.** Up to `CTV_MAX_BYTES` (240KB by default) of the raw session transcript, per session. Transcripts contain whatever was on your screen: file contents, command output, pasted config. If a secret went through a Claude Code session, it is in that transcript, and it will be sent.
- **Where it goes.** Through your own `claude` CLI, to Anthropic, under whatever terms your existing plan already carries. This project adds no service, no server, and no telemetry. Nothing is uploaded anywhere else.
- **What is kept.** A plaintext markdown note in your vault folder, plus a plaintext log of what ran. Both live only on your machine.
- **What is never read.** Nothing outside `~/.claude/projects` and the vault folder you name.

If some sessions are too sensitive to send, add a path fragment to `CTV_SKIP_PATTERNS` and they are skipped entirely.

## Install

```sh
git clone https://github.com/emmanuelwunjc/claude-to-vault
cd claude-to-vault
./install.sh --vault ~/obsidian/sessions
```

That writes a config file and wires a `SessionEnd` hook into `~/.claude/settings.json`, preserving any hooks you already have. New sessions get a note when they end.

**This directory becomes load-bearing.** The hook is wired as an absolute path to wherever you cloned it. Move or delete it and notes silently stop, with only a log line as evidence. Clone it somewhere permanent, and re-run `install.sh` if you move it. A `git pull` changes behavior immediately, since nothing is compiled or copied.

## Try it before you trust it

```sh
./bin/ctv-backfill --preview    # prints ONE note to stdout, writes nothing
```

That is the real pipeline on a real transcript of yours. If you do not like the note, edit `prompts/session-summary.md` and run it again. Nothing touches your vault until you are happy.

## Distilling past sessions

```sh
./bin/ctv-backfill --dry-run    # honest counts, no model calls
./bin/ctv-backfill --limit 20   # start small
./bin/ctv-backfill              # everything not yet distilled
./bin/ctv-backfill -j 8         # 8 at a time (default 3)
```

`--dry-run` prints how many transcripts exist, how many are noise, how many already have a note, and how many would actually be distilled.

**A first backfill is the expensive moment.** It is one model call per session across every session you have ever run, which can be hundreds. Each call sends up to 240KB of transcript. On a subscription those headless calls draw down your usage window, and `-j 8` draws it down eight at a time. Check the count with `--dry-run`, work out what that costs on your own plan, and use `--limit` rather than committing to all of it at once.

Backfill is idempotent and resumable: a session that already has a note is skipped with no model call, so stopping and restarting is cheap.

## What a note looks like

```markdown
---
date: 2026-08-05
project: sales_pipeline
session: 11112222-3333-4444-5555-666677778888
tags: [session-log]
---

# sales_pipeline (2026-08-05)

## Goal
Find out why the importer was silently dropping rows.

## Decisions
- Validate at the loader, not in each query. The bad rows are malformed upstream,
  so filtering per-query would leave every future caller to rediscover it.

## Learnings
- `read_csv` coerces the id column to float when any value is blank, turning
  `01234` into `1234.0`. Pass `dtype=str` explicitly.

## Verified
- Row counts match the source file. Same number in as out.
```

Frontmatter is computed by the code. Prose is written by the model. The model never invents a date, a project, or a session id. Notes produced by `ctv-backfill` are tagged `[session-log, backfill]`, so you can tell reconstructed history from notes written live.

## Configuration

`~/.config/claude-to-vault/config.sh`, written by the installer. Precedence is environment variable, then config file, then built-in default.

| Setting | Default | What it does |
|---|---|---|
| `CTV_VAULT_DIR` | `~/claude-vault/sessions` | Where notes go. The one you must get right. |
| `CTV_MODEL` | `claude-haiku-4-5-20251001` | Model that distils. Cheap and fast is correct here. |
| `CTV_MAX_BYTES` | `240000` | Transcript bytes sent per session. See rule 3. |
| `CTV_MIN_LINES` | `2` | Transcripts shorter than this get no note. |
| `CTV_POST_WRITE` | *(none)* | Command run after each note, with the note path as `$1`. Use it to index into a search tool. |
| `CTV_SKIP_PATTERNS` | `claude-mem-observer` | Path fragments to treat as noise. Space separated. |
| `CTV_CLAUDE_BIN` | `claude` | Full path to the CLI. Set this if `claude` is not on the PATH your hooks inherit. |
| `CTV_PROMPT` | `prompts/session-summary.md` | The distillation prompt. Point it elsewhere to change note shape. |
| `CTV_PROJECTS_DIR` | `~/.claude/projects` | Where Claude Code keeps transcripts. |
| `CTV_LOGFILE` | `~/.local/state/claude-to-vault/run.log` | Every run logs why it did what it did. |

Config lines use the `: "${VAR:=value}"` form so an environment variable still wins. A plain `VAR=value` there would override the environment, which silently defeats a one-off run.

Re-running `install.sh` keeps a config you have edited and updates only the vault path.

## The five rules

Each of these exists because it broke in production. They live in one file, `lib/vault-lib.sh`, sourced by both the hook and the backfill so the two can never drift.

**1. Distil every real session.** Anything with real content gets a note, even a short one.

**2. Never save an error as a note.** A failed model call returns an error string. Written naively, that string becomes the note body and looks like a summary until you read it. Errors are detected and skipped, so the session is retried later instead of being recorded as done. Auth and billing failures are caught too, because a fresh install answers `Not logged in · Please run /login` on stdout like a normal reply.

The check gates on line count, not byte length. A real note *about* debugging a rate limit contains the words "rate limit exceeded", and a naive substring match would delete it forever, since every retry hits the same match. Errors are one or two lines. Summaries are many.

**3. Never blow the model's context.** Transcripts reach 18MB. Sent whole, that is an ~800k-token request against a 200k limit, which fails every time on exactly the long sessions most worth keeping. Oversized transcripts are cut to head plus tail: what the session set out to do, and where it landed.

Worst-case tokenization of dense JSON is about 2.2 bytes per token, so the 240KB default is at most ~110k tokens, plus roughly 25k for Claude Code's own system prompt and tool definitions. A non-numeric value like `CTV_MAX_BYTES=1M` falls back to the default rather than silently disabling truncation.

**4. Skip noise, but only noise.** Subagent transcripts and the pipeline's own distillation runs are not sessions. The test for "is this the pipeline talking to itself" reads only line 1 of the transcript, because scanning the whole file meant any session that happened to *read this code* was classified as noise and dropped forever.

**5. One session, one note.** Deduplication keys on the session id, never the filename. The hook dates a note today; the backfill dates it from file mtime; both derive the project name. If any of those disagree, a filename comparison writes a second note for the same session.

The project name is read from the `cwd` the transcript itself records. Claude Code encodes project directories by replacing `/` and `_` alike with `-`, so `-Users-me-code-sales-pipeline` cannot be decoded back. Guessing from it turns `sales_pipeline` into `tracking`.

## Failure is loud

Every exit path writes one line to the log saying why: skipped as noise, skipped as empty, aborted because the CLI is missing, wrote a note. The model call records its exit status, which separates "the call failed" (retired model id, auth, no credit) from "the model returned nothing".

This is the whole reason the log exists. The original version sent errors to `/dev/null` and exited 0, so a broken pipeline and a correctly quiet one were indistinguishable. It produced garbage for months before anyone noticed.

```sh
tail ~/.local/state/claude-to-vault/run.log
```

## It is not working

No notes appearing is the expected symptom of almost every problem, so start here:

```sh
tail -20 ~/.local/state/claude-to-vault/run.log
```

Every run writes one line saying what it did and why. What you will see:

- `ABORT claude CLI not found`: the hook's PATH does not include `claude`. Set `CTV_CLAUDE_BIN` to its full path in your config.
- `SKIP noise` / `SKIP empty`: working as intended. Subagent runs and one-line sessions do not get notes.
- `SKIP error reply`: the model call failed, usually login or usage limits. The session is not marked done, so it is retried later.
- `FAILED could not write`: the vault path is not writable, or the disk is full.
- **Nothing at all, and no log file:** the hook never ran. Either the clone moved (the hook is wired as an absolute path) or `settings.json` lost its entry. Re-run `install.sh`.

Notes going to a folder you did not expect: check the resolved path with

```sh
grep CTV_VAULT_DIR ~/.config/claude-to-vault/config.sh
```

## Uninstall

```sh
./install.sh --uninstall
```

Removes only its own entry from `settings.json`, leaving other hooks alone. Your notes are never touched.

It deliberately leaves behind your config and log, so reinstalling restores your settings. For a clean sweep, delete these by hand:

- `~/.config/claude-to-vault/` (config, plus a `config.sh.bak` from each reinstall)
- `~/.local/state/claude-to-vault/` (the log)
- `~/.claude/settings.json.ctv-backup` (a copy of your settings from before install)
- the vault directory itself, if you want the notes gone too

## Tests

```sh
./test/selftest.sh      # 24 assertions: the five rules, in isolation
./test/integration.sh   # 14 assertions: the real hook against a stub CLI
```

Neither needs the network, a login, or a single token. `integration.sh` runs the actual `SessionEnd` hook against a fake `claude` binary and checks that a note appears with correct frontmatter, that a second run writes no duplicate, and that an auth error never reaches the vault.

CI (`.github/workflows/ci.yml`) runs both on macOS and Linux, plus `shellcheck`, plus a check that install and uninstall leave a pre-existing `SessionEnd` hook intact.

Every assertion covers a bug that actually shipped, including the ones where the *wrong* behavior was to throw a real note away. If you relax a rule, read its comment in `lib/vault-lib.sh` first.

## Gotcha

Killing a backfill does not stop work already in flight. Its workers are spawned through `xargs` and do not carry the script's name, so `pkill -f ctv-backfill` leaves them running and still writing. To stop everything:

```sh
pkill -f ctv-backfill; pkill -f "claude -p --model claude-haiku"
```

## Layout

```
lib/vault-lib.sh       the five rules and all config. Change behavior here.
hooks/session-end.sh   SessionEnd hook. Returns instantly, works detached.
bin/ctv-backfill       distil past transcripts. Idempotent, resumable.
prompts/               the distillation prompt. Edit to change note shape.
install.sh             config + settings.json wiring, and uninstall.
test/selftest.sh       the five rules, asserted.
test/integration.sh    the hook end to end, against a stub CLI.
.github/workflows/     CI on macOS and Linux.
```

Requires bash, `python3` (to edit `settings.json` as JSON rather than as text), and the `claude` CLI. Tested on macOS and Linux. Works under WSL. Native Windows does not work: the hook is bash and relies on `nohup`.

## License

MIT
