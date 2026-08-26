#!/bin/sh
# Apply, snapshot, or diff Stalwart desired-state NDJSON using stalwart-cli only.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PLAN_DIR="${STALWART_PLAN_DIR:-$ROOT/stalwart/plan}"
TYPES_FILE="${STALWART_TYPES_FILE:-$ROOT/stalwart/types.txt}"
STALWART_URL="${STALWART_URL:-https://mail.solace.onl}"
STALWART_TOKEN="${STALWART_TOKEN:-${STALWART_ADMIN_TOKEN:-}}"
DOMAIN_ID="${STALWART_DOMAIN_ID:-b}"

usage() {
	printf 'usage: %s apply|dry-run|snapshot|drift|dns-publish [--write DIR]\n' "$(basename "$0")" >&2
	exit 2
}

[ -n "${STALWART_TOKEN}" ] || {
	printf 'STALWART_TOKEN or STALWART_ADMIN_TOKEN is required\n' >&2
	exit 1
}

cli() {
	stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_TOKEN" "$@"
}

concat_plan() {
	[ -d "$PLAN_DIR" ] || {
		printf 'missing plan dir: %s\n' "$PLAN_DIR" >&2
		exit 1
	}
	cat "$PLAN_DIR"/*.ndjson
}

snapshot_types() {
	# shellcheck disable=SC2046
	cli snapshot $(grep -v '^[[:space:]]*$' "$TYPES_FILE") \
		--allow-unresolved Tenant,Certificate,Account,DkimSignature,MtaRoute,PublicKey,Directory,Role \
		--quiet "$@"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift || true

write_dir=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--write)
			write_dir="${2:-}"
			[ -n "$write_dir" ] || usage
			shift 2
			;;
		*)
			usage
			;;
	esac
done

case "$cmd" in
	apply)
		tmp="$(mktemp)"
		concat_plan >"$tmp"
		cli apply --file "$tmp"
		rm -f "$tmp"
		cli create Action/ReloadSettings >/dev/null 2>&1 || true
		;;
	dry-run)
		tmp="$(mktemp)"
		concat_plan >"$tmp"
		cli apply --file "$tmp" --dry-run
		rm -f "$tmp"
		;;
	snapshot)
		if [ -n "$write_dir" ]; then
			mkdir -p "$write_dir"
			snapshot_types --output "$write_dir/snapshot.ndjson"
			printf 'wrote %s/snapshot.ndjson\n' "$write_dir"
		else
			snapshot_types
		fi
		;;
	drift)
		live="$(mktemp)"
		want="$(mktemp)"
		snapshot_types --output "$live"
		concat_plan >"$want"
		python3 - "$live" "$want" <<'PY'
import json, sys
from pathlib import Path

def load(path):
    ops = []
    for line in Path(path).read_text().splitlines():
        if line.strip():
            ops.append(json.loads(line))
    return ops

def index(ops):
    out = {}
    for op in ops:
        obj = op.get("object")
        val = op.get("value")
        if op.get("@type") == "update":
            out[(obj, "_singleton")] = val
        elif isinstance(val, dict):
            for cid, body in val.items():
                key = None
                if isinstance(body, dict):
                    key = body.get("name") or body.get("url") or body.get("description") or cid
                out[(obj, key)] = body
    return out

live, want = index(load(sys.argv[1])), index(load(sys.argv[2]))
missing = sorted(set(want) - set(live))
extra = sorted(k for k in live if k not in want)
print(f"plan objects: {len(want)}  live snapshot objects: {len(live)}")
if missing:
    print("in plan, not in snapshot:")
    for item in missing:
        print(f"  {item[0]} {item[1]}")
if extra:
    print("in snapshot, not in plan (ok for unmanaged types):")
    for item in extra:
        print(f"  {item[0]} {item[1]}")
if missing:
    sys.exit(1)
print("no missing plan objects in live snapshot")
PY
		status=$?
		rm -f "$live" "$want"
		exit "$status"
		;;
	dns-publish)
		due="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
		cli create Task/DnsManagement \
			--field "domainId=${DOMAIN_ID}" \
			--field 'updateRecords={"dkim":true,"dmarc":true,"tlsRpt":true,"srv":true}' \
			--field "status={\"@type\":\"Pending\",\"due\":\"${due}\"}"
		;;
	*)
		usage
		;;
esac
