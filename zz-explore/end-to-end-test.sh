#!/usr/bin/env bash
# End-to-end verification for stats-me + stats-me-vm.
#
# 1. Spin up VictoriaMetrics with -graphiteListenAddr=:12003,
#    -httpListenAddr=:18428, fresh -storageDataPath
# 2. Spin up the stats-me wrapper pointed at a config that:
#    - listens on UDP 18125
#    - flushes every 5s
#    - uses console + graphite backends, graphiteHost=127.0.0.1:12003
# 3. Spam UDP packets to stats-me
# 4. Wait for one or two flushes
# 5. Query VM via GET /api/v1/query?query=foo and confirm the value
# 6. Clean up
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stats-me-e2e.XXXXXXXX")"
trap 'echo "[cleanup] $WORK"; jobs -p | xargs -r kill 2>/dev/null; sleep 0.5; rm -rf "$WORK"' EXIT

VM_GRAPHITE_PORT=12003
VM_HTTP_PORT=18428
STATSD_PORT=18125
FLUSH_MS=5000

echo "[setup] work dir: $WORK"
mkdir -p "$WORK/vm-data" "$WORK/log"

# --- statsd config ---
cat > "$WORK/statsd-config.js" <<EOF
{
  port: $STATSD_PORT,
  flushInterval: $FLUSH_MS,
  backends: ["./backends/console", "./backends/graphite"],
  graphiteHost: "127.0.0.1",
  graphitePort: $VM_GRAPHITE_PORT,
  graphite: { legacyNamespace: false }
}
EOF

echo "[setup] building stats-me + VM ..."
STATS_ME_BIN="$(nix build --print-out-paths --no-link "$ROOT#stats-me")/bin/stats-me"
VM_BIN="$(nix build --print-out-paths --no-link nixpkgs#victoriametrics)/bin/victoria-metrics"
echo "[setup] stats-me: $STATS_ME_BIN"
echo "[setup] victoria-metrics: $VM_BIN"

# --- start VM ---
echo "[run] starting victoria-metrics ..."
"$VM_BIN" \
  -graphiteListenAddr=127.0.0.1:$VM_GRAPHITE_PORT \
  -httpListenAddr=127.0.0.1:$VM_HTTP_PORT \
  -storageDataPath="$WORK/vm-data" \
  -retentionPeriod=30d \
  -loggerOutput=stdout \
  >"$WORK/log/vm.log" 2>&1 &
vm_pid=$!
echo "[run] vm pid: $vm_pid"

# Wait for VM's HTTP endpoint.
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$VM_HTTP_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if ! curl -fsS "http://127.0.0.1:$VM_HTTP_PORT/health" >/dev/null 2>&1; then
  echo "[FAIL] VM /health didn't come up after 10s"
  echo "--- vm log ---"; cat "$WORK/log/vm.log"
  exit 1
fi
echo "[run] VM healthy on 127.0.0.1:$VM_HTTP_PORT"

# Verify VM's graphite listener too.
if ! nc -z 127.0.0.1 $VM_GRAPHITE_PORT 2>/dev/null; then
  echo "[FAIL] VM never opened graphite TCP $VM_GRAPHITE_PORT"
  echo "--- vm log ---"; cat "$WORK/log/vm.log"
  exit 1
fi
echo "[run] VM graphite listener on 127.0.0.1:$VM_GRAPHITE_PORT"

# --- start stats-me ---
echo "[run] starting stats-me wrapper ..."
"$STATS_ME_BIN" "$WORK/statsd-config.js" >"$WORK/log/statsd.log" 2>&1 &
statsd_pid=$!
echo "[run] statsd pid: $statsd_pid"

for _ in $(seq 1 25); do
  grep -q "server is up" "$WORK/log/statsd.log" 2>/dev/null && break
  sleep 0.2
done
if ! grep -q "server is up" "$WORK/log/statsd.log"; then
  echo "[FAIL] stats-me never printed 'server is up' after 5s"
  echo "--- statsd log ---"; cat "$WORK/log/statsd.log"
  exit 1
fi
echo "[run] stats-me listening on 127.0.0.1:$STATSD_PORT"

# --- spam packets every 250ms for ~2 flush intervals ---
echo "[send] spamming foo:1|c every 250ms for ~$((FLUSH_MS * 2 / 1000))s ..."
end_ts=$(( $(date +%s) + FLUSH_MS * 2 / 1000 + 2 ))
sent=0
while [ "$(date +%s)" -lt "$end_ts" ]; do
  echo "foo:1|c" | nc -u -w0 127.0.0.1 $STATSD_PORT
  sent=$((sent + 1))
  sleep 0.25
done
echo "[send] sent $sent packets"

# Give VM a beat to ingest the last flush.
sleep 1

# --- query VM ---
# Statsd's graphite backend with legacyNamespace=false names counters
# `<prefix>.<name>.count` (default `stats_counts.foo` for legacy or
# `<key>.count` for non-legacy). Probe a few candidate names so we
# don't have to guess; print whatever VM has.
echo "[verify] enumerating series VM saw ..."
all_series=$(curl -fsS "http://127.0.0.1:$VM_HTTP_PORT/api/v1/label/__name__/values" || echo '{}')
echo "[verify] series: $all_series"

# Print metrics matching "foo".
foo_series=$(curl -fsS --get \
  --data-urlencode 'match[]={__name__=~".*foo.*"}' \
  "http://127.0.0.1:$VM_HTTP_PORT/api/v1/series" \
  || echo '{}')
echo "[verify] foo-related series: $foo_series"

# Pull the raw datapoints via VM's /api/v1/export, which bypasses
# PromQL semantics entirely and returns one JSON line per series
# with `values` and `timestamps` arrays. Most direct way to confirm
# data made it into VM's storage.
foo_export=$(curl -fsS --get \
  --data-urlencode 'match[]=stats.counters.foo.count' \
  "http://127.0.0.1:$VM_HTTP_PORT/api/v1/export" \
  || echo '')
echo "[verify] /api/v1/export response: $foo_export"

# Pass condition: at least one non-zero value in the values array.
if echo "$foo_export" | grep -qE '"values":\[[^]]*[1-9][0-9]*'; then
  echo "[PASS] stats-me → VM pipeline works"
  exit 0
fi

echo "[FAIL] no foo values found in VM"
echo "--- vm log (head) ---"; head -40 "$WORK/log/vm.log"
echo "--- statsd log (head) ---"; head -40 "$WORK/log/statsd.log"
exit 1
