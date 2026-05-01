#!/usr/bin/env bash
# Smoke-test stats-me-query against a live stats-me + VM pipeline.
# Reuses the same shape as zz-explore/end-to-end-test.sh but exercises
# the CLI's subcommands at the end instead of curl-ing VM directly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sm-cli-test.XXXXXXXX")"
trap 'jobs -p | xargs -r kill 2>/dev/null; sleep 0.3; rm -rf "$WORK"' EXIT

VM_GRAPHITE_PORT=12003
VM_HTTP_PORT=18428
STATSD_PORT=18125

mkdir -p "$WORK/vm-data"

echo "[setup] building binaries ..."
VM_BIN="$(nix build --print-out-paths --no-link nixpkgs#victoriametrics)/bin/victoria-metrics"
STATS_ME_BIN="$(nix build --print-out-paths --no-link "$ROOT#stats-me")/bin/stats-me"
QUERY_BIN="$(nix build --print-out-paths --no-link "$ROOT#stats-me-query")/bin/stats-me-query"

cat > "$WORK/cfg.js" <<EOF
{
  port: $STATSD_PORT,
  flushInterval: 5000,
  backends: ["./backends/console", "./backends/graphite"],
  graphiteHost: "127.0.0.1",
  graphitePort: $VM_GRAPHITE_PORT,
  graphite: { legacyNamespace: false }
}
EOF

echo "[run] starting VM ..."
"$VM_BIN" \
  -graphiteListenAddr=127.0.0.1:$VM_GRAPHITE_PORT \
  -httpListenAddr=127.0.0.1:$VM_HTTP_PORT \
  -storageDataPath="$WORK/vm-data" \
  -loggerOutput=stdout \
  >"$WORK/vm.log" 2>&1 &
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$VM_HTTP_PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "[run] starting stats-me ..."
"$STATS_ME_BIN" "$WORK/cfg.js" >"$WORK/stats.log" 2>&1 &
for _ in $(seq 1 25); do
  grep -q "server is up" "$WORK/stats.log" 2>/dev/null && break
  sleep 0.2
done

echo "[send] spamming foo:1|c for ~12s (>2 flushes) ..."
for _ in $(seq 1 30); do
  echo "foo:1|c" | nc -u -w0 127.0.0.1 $STATSD_PORT
  sleep 0.4
done
sleep 2

export STATS_ME_VM_URL="http://127.0.0.1:$VM_HTTP_PORT"

echo
echo "=== stats-me-query labels ==="
"$QUERY_BIN" labels

echo
echo "=== stats-me-query series '.*foo.*' ==="
"$QUERY_BIN" series '.*foo.*'

echo
echo "=== raw curl GET /api/v1/export ==="
curl -is "http://127.0.0.1:$VM_HTTP_PORT/api/v1/export?match%5B%5D=stats.counters.foo.count" | head -10

echo
echo "=== raw curl POST /api/v1/export ==="
curl -is "http://127.0.0.1:$VM_HTTP_PORT/api/v1/export" \
  --data-urlencode 'match[]=stats.counters.foo.count' | head -10

echo
echo "=== stats-me-query export 'stats.counters.foo.count' ==="
"$QUERY_BIN" export 'stats.counters.foo.count'

echo
echo "=== stats-me-query range 'stats.counters.foo.count' 60 ==="
"$QUERY_BIN" range 'stats.counters.foo.count' 60

echo
echo "[PASS] CLI exercised all subcommands"
