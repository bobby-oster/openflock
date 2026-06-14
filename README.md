# OpenFlock

Watch your flock of AI coding agents: throughput, token burn, usage limits, and
who needs you.

## Why

If you run multiple coding agents in parallel — across terminal sessions today,
web and mobile eventually — there's no single glanceable place that answers:

- How many agents are running, and on which models?
- How many tokens has each agent's session consumed?
- Which agents are active, and which are blocked waiting on me?
- Where am I against my session/weekly usage limits?
- At my current burn rate, do I run out before the limit resets?

Session control already exists (Claude Code's Agent View). OpenFlock is the
**observation and economics layer**: it tells you an agent stopped or that
you'll hit your weekly limit by Thursday — you decide what to do about it.

## Status

Pre-alpha, but running. A SwiftPM workspace with a `FlockCore` library and a
macOS menu bar app (`OpenFlockApp`) is in place. What works today:

- Scans Claude Code transcripts to find sessions, grouping sub-agent
  transcripts under their parent session.
- Per-agent state read from the shape of the last transcript event, not file
  mtime: **working** (mid-turn), **waiting** (turn ended, your move),
  **blocked** (a tool call left pending — usually a permission prompt), and
  **stale**. The menu bar leads with whatever needs attention.
- Session list titled by project directory, leading with output tokens
  (cache-inclusive totals on the secondary line); synthetic and empty
  sessions are filtered out.
- Throughput: fresh-token (input + output) burn rate now and as a 10-minute
  average, with cache-inclusive rate as a secondary figure and an optional
  compact rate in the menu bar label.
- Panel components (throughput, session list, menu bar rate) individually
  toggleable, persisted across launches.

Not yet built: usage-limit tracking and anything beyond Claude Code terminal
sessions. macOS first.

## Name styling

One rule, applied everywhere: **OpenFlock** for humans (prose, app name),
**`openflock`** for machines (repo, binary, package, formula). Never hyphenated.

## License

[MIT](LICENSE)
