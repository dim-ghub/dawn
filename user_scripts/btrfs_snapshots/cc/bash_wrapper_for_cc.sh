#!/usr/bin/env bash
# Finds a coordinated matching Root/Home snapshot pair and stages both restores together.

set -euo pipefail

if (( EUID != 0 )); then
    printf '%s\n' "[!] This script requires root privileges. Please run with sudo." >&2
    exit 1
fi

if (( $# < 1 || $# > 2 )); then
    printf 'Usage: %s TARGET_DATE [TARGET_DESC]\n' "$(basename -- "$0")" >&2
    exit 64
fi

TARGET_DATE=$1
TARGET_DESC=${2-}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MANAGER_SCRIPT="${SCRIPT_DIR}/04_dusky_snapshot_manager.py"

if [[ ! -f "$MANAGER_SCRIPT" || ! -r "$MANAGER_SCRIPT" ]]; then
    printf '%s\n' "[!] Error: Manager script not found or not readable at $MANAGER_SCRIPT" >&2
    exit 1
fi

TMP_MANAGER="$(mktemp -p /run snapctl-manager.XXXXXX.py)"
trap 'rm -f -- "$TMP_MANAGER"' EXIT
install -m 0600 -- "$MANAGER_SCRIPT" "$TMP_MANAGER"

MANAGER_CMD=(python3 "$TMP_MANAGER")

select_root_id() {
    python3 /dev/fd/3 "$TARGET_DATE" 3<<'PY'
import json
import sys

target_date = sys.argv[1]

try:
    snapshots = json.load(sys.stdin)
except Exception as exc:
    print(f"[!] Fatal: Failed to parse Root snapshot list JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

matches = [str(item["id"]) for item in snapshots if item.get("raw_date") == target_date]

if len(matches) == 1:
    print(matches[0])
    raise SystemExit(0)

if not matches:
    print(f"[!] Fatal: Could not find Root snapshot for exact date: {target_date}", file=sys.stderr)
    raise SystemExit(1)

print(f"[!] Fatal: Multiple Root snapshots matched exact date: {target_date}", file=sys.stderr)
raise SystemExit(1)
PY
}

select_home_id() {
    python3 /dev/fd/3 "$TARGET_DATE" "$TARGET_DESC" 3<<'PY'
import json
import re
import sys

target_date = sys.argv[1]
target_desc = sys.argv[2]

try:
    snapshots = json.load(sys.stdin)
except Exception as exc:
    print(f"[!] Fatal: Failed to parse Home snapshot list JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

def minute_prefix(value: str) -> str | None:
    match = re.search(r"^(.*\d{2}:\d{2})", value)
    return match.group(1) if match else None

exact = [str(item["id"]) for item in snapshots if item.get("raw_date") == target_date]
if len(exact) == 1:
    print(exact[0])
    raise SystemExit(0)

if len(exact) > 1:
    print(f"[!] Fatal: Multiple Home snapshots matched exact date: {target_date}", file=sys.stderr)
    raise SystemExit(1)

if target_desc:
    target_minute = minute_prefix(target_date)
    if target_minute:
        fuzzy = [
            str(item["id"])
            for item in snapshots
            if item.get("description") == target_desc
            and minute_prefix(item.get("raw_date", "")) == target_minute
        ]

        if len(fuzzy) == 1:
            print(fuzzy[0])
            raise SystemExit(0)

        if len(fuzzy) > 1:
            print(
                "[!] Fatal: Multiple Home snapshots matched the fuzzy minute+description search; "
                "aborting to avoid restoring the wrong snapshot.",
                file=sys.stderr,
            )
            raise SystemExit(1)

print("[!] Fatal: Could not find a unique matching Home snapshot for coordinated restore.", file=sys.stderr)
raise SystemExit(1)
PY
}

if ! ROOT_JSON="$("${MANAGER_CMD[@]}" -c root --json -l)"; then
    printf '%s\n' "[!] Fatal: Failed to query Root snapshots." >&2
    exit 1
fi

if ! HOME_JSON="$("${MANAGER_CMD[@]}" -c home --json -l)"; then
    printf '%s\n' "[!] Fatal: Failed to query Home snapshots." >&2
    exit 1
fi

if ! ROOT_ID="$(printf '%s' "$ROOT_JSON" | select_root_id)"; then
    exit 1
fi

if ! HOME_ID="$(printf '%s' "$HOME_JSON" | select_home_id)"; then
    exit 1
fi

printf '%s\n' "[*] Found coordinated snapshot pair: Root=$ROOT_ID Home=$HOME_ID"
printf '%s\n' "[*] Staging coordinated restore for next reboot..."
"${MANAGER_CMD[@]}" --restore-pair root "$ROOT_ID" home "$HOME_ID"
