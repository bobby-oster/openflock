# Transcript Fixture Policy

All transcript fixtures in this tree must be fabricated by hand. Never copy,
capture, redact, or scrub transcript data from a real machine or a real agent
run.

Fixtures model the parser input shape only. Include the smallest set of fields
the parser reads:

| Field | Convention |
| --- | --- |
| `type` | Use documented event types such as `assistant` and `user`. |
| `sessionId` | Use fake ids such as `session-0001`. |
| `cwd` | Use `/Users/dev/example` or another `/Users/dev/...` path. |
| `slug` | Use generic task labels such as `example-task`. |
| `timestamp` | Use a fixed synthetic timestamp. |
| `message.model` | Use generic invented model names. |
| `message.usage` | Use invented token counts. |
| `message.stop_reason` | Use the shape needed by the test case. |
| `message.content` | Use only minimal typed blocks, such as `{"type":"tool_use"}`. |

## Authoring Recipe

1. Start from the documented transcript shape, not from a captured transcript.
2. Hand-write the minimal JSONL lines needed for one parser behavior.
3. Use obviously fake values for every path, id, model, timestamp, and token
   count.
4. Keep prompts, tool names, tool inputs, and tool outputs out of fixtures unless
   a parser test needs the field. Prefer `{"type":"tool_use"}` for tool blocks.
5. Run `scripts/check-fixtures.sh`.
6. Read the fixture diff before committing. The guard is a backstop, not a
   substitute for review.

## Pre-Commit Checklist

- The fixture was authored by hand from the documented shape.
- The fixture contains no real user name, host name, email address, project path,
  prompt, tool input, tool output, token, or secret.
- Any home-directory path uses the `dev` placeholder user.
- `scripts/check-fixtures.sh` passes.
