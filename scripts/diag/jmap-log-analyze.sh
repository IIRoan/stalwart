#!/bin/sh
# Analyze Stalwart JMAP timing from debug log (run on container via railway ssh).
LOG="${1:-/var/log/stalwart/stalwart.log.$(date -u +%Y-%m-%d)}"
echo "Log: $LOG"
echo "=== Slow JMAP methods (>10ms) ==="
grep 'jmap.method-call' "$LOG" 2>/dev/null | grep -E 'elapsed = ([1-9][0-9]{2,}|[1-9][0-9]ms)' | tail -30
echo
echo "=== Email/get calls ==="
grep 'jmap.method-call' "$LOG" 2>/dev/null | grep 'Email/get' | tail -15
echo
echo "=== cannot-calculate-changes (last 10) ==="
grep 'cannot-calculate-changes' "$LOG" 2>/dev/null | tail -10
echo
echo "=== concurrent / rate limits ==="
grep -E 'concurrent-request|too-many-requests|s3-error' "$LOG" 2>/dev/null | tail -10
echo
echo "=== Slow HTTP connections (>500ms) ==="
grep 'http.connection-end' "$LOG" 2>/dev/null | grep -E 'elapsed = [5-9][0-9]{2,}ms|elapsed = [0-9]{4,}ms' | tail -15
