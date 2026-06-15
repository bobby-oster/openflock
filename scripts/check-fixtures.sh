#!/bin/sh
set -eu

fixtures_dir="${1:-Tests/Fixtures}"

if [ ! -d "$fixtures_dir" ]; then
  echo "No fixture directory found: $fixtures_dir"
  exit 0
fi

status=0

check_pattern() {
  label="$1"
  pattern="$2"
  if matches=$(grep -RInE "$pattern" "$fixtures_dir" 2>/dev/null); then
    echo "Fixture leak guard failed: $label"
    echo "$matches"
    status=1
  fi
}

check_pattern "real-looking home path" '/Users/([^d]|d[^e]|de[^v]|dev[^/])[^[:space:]"]*'
check_pattern "email address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
check_pattern "OpenAI-style token prefix" 'sk-[A-Za-z0-9_-]+'
check_pattern "GitHub token prefix" 'ghp_[A-Za-z0-9_]+'
check_pattern "AWS access key prefix" 'AKIA[A-Z0-9]+'
check_pattern "private key marker" 'BEGIN .* PRIVATE KEY'

if ! python3 - "$fixtures_dir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
allowed = {
    "type",
    "sessionId",
    "cwd",
    "slug",
    "timestamp",
    "payload",
    "message",
    "producer",
    "modelsShapeOfVersion",
    "authoredAt",
    "fabricated",
    "cases",
    "notes",
}
failed = False

for path in sorted(root.rglob("*")):
    if path.suffix not in {".json", ".jsonl"}:
        continue
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        print(f"Fixture leak guard failed: unreadable UTF-8: {path}")
        failed = True
        continue
    for number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            print(f"Fixture leak guard failed: invalid JSON: {path}:{number}: {error.msg}")
            failed = True
            continue
        if not isinstance(value, dict):
            print(f"Fixture leak guard failed: top-level JSON is not an object: {path}:{number}")
            failed = True
            continue
        for key in value:
            if key not in allowed:
                print(f"Fixture leak guard failed: unexpected top-level key '{key}': {path}:{number}")
                failed = True

sys.exit(1 if failed else 0)
PY
then
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Fixture leak guard passed."
fi

exit "$status"
