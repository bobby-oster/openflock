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

Pre-alpha. Naming is settled; the first lines of real code are not yet written.
macOS first.

## Name styling

One rule, applied everywhere: **OpenFlock** for humans (prose, app name),
**`openflock`** for machines (repo, binary, package, formula). Never hyphenated.

## License

[MIT](LICENSE)
