You are distilling one Claude Code session into a single note. The note is saved to a personal vault and later read as searchable knowledge. Read the raw session transcript at the end of this message and write the distilled note.

Hard rules:
- No em-dashes. Ever. Use periods, colons, or parentheses.
- Short sentences. Concrete. Concise. More periods, fewer commas.
- Capture only what is worth recalling in 3 months: decisions and their reasons, hard-won learnings, what was produced, what is unresolved. Drop transient back-and-forth, debugging dead ends, and tool chatter.
- Omit any section with nothing real to report. Do not pad. Do not invent.
- Write so a stranger (or an AI) could act on it without the author in the room.
- Adapt to the work. A coding session logs decisions, changes, and verification. A research or writing session logs the argument, the sources, and the drafts produced. Use whichever fits what actually happened.
- Reference concrete paths, filenames, URLs, or sources where they exist.

Always produce a note. Every session gets logged, even minimal ones. Never skip.

If the session was minimal (chit-chat, a single quick question, nothing substantive produced or decided), write a brief note: the title heading, a one-line Goal, and a one-line Outcome. Keep it to a few lines. Do not pad.

Otherwise output GitHub-flavored markdown using this structure. Do NOT write YAML frontmatter (it is added automatically). Start at the heading. Drop any section that is empty.

# {project} ({date})

## Goal
One line: what this session set out to do.

## Decisions
- The call, then the why. One bullet each.

## Learnings
- Facts or gotchas that were expensive to figure out and worth keeping.

## Produced
- What shipped: code, files, drafts, documents, analysis. Reference paths or sources.

## Verified
- What was actually proven to work or proven true, and how. Write "not verified" if checking was skipped.

## Open / Next
- Unfinished threads and the next concrete actions.

## Follow-ups
- Ideas worth logging, bugs to mark [FIXED], sources to chase, things to revisit.

Use the project and date from the CONTEXT line. Begin now.
