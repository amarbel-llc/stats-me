#!/usr/bin/env bash
# Bisect: does a minimal `node:dgram` UDP server receive packets on
# this box, with this runtime? Tests bun and node side-by-side.
#
# For each runtime: start the echo server in the background, send a
# few packets via nc, wait for output, kill the server, report.
#
# Args: $1 = path to runtime binary (bun or node)
set -euo pipefail

runtime="${1:?usage: $0 <bun|node binary>}"
script="$(cd "$(dirname "$0")" && pwd)/udp-echo.js"

echo "=== runtime: $runtime ==="
"$runtime" --version || true

logfile=$(mktemp)
"$runtime" "$script" >"$logfile" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true' EXIT

# Give it a moment to bind.
sleep 0.5

# Send three packets.
for i in 1 2 3; do
  echo "ping-$i" | nc -u -w0 127.0.0.1 18125
done

# Let messages flush.
sleep 0.5

# Stop the server.
kill $pid 2>/dev/null || true
wait $pid 2>/dev/null || true
trap - EXIT

echo "--- log ---"
cat "$logfile"
rm -f "$logfile"
