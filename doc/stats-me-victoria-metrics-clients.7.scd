stats-me-victoria-metrics-clients(7)

# NAME

stats-me-victoria-metrics-clients - querying and pushing to a
stats-me-managed VictoriaMetrics

# DESCRIPTION

The *stats-me-victoria-metrics* home-manager module runs upstream
*victoria-metrics*(1) under launchd or systemd-user as a personal
time-series store. It exposes two ingress and one egress surface that
clients interact with:

[[ *Endpoint*
:[ *Default*
:[ *Wire*
|  Graphite plaintext receiver
:  *127.0.0.1:2003*
:  TCP+UDP, _<metric.name> <value> <timestamp>\\n_
|  HTTP query / management
:  *127.0.0.1:8428*
:  HTTP/1.1, /api/v1/query, /api/v1/series, ...
|  PromQL
:  served by the HTTP endpoint
:  read-only, see VM docs

There is no auth and no library API. Anything that can speak HTTP or
graphite plaintext is a viable client. For daemon configuration see
the *services.stats-me-victoria-metrics* options in the home-manager
module (_nix/hm/victoria-metrics.nix_ in the *stats-me* flake).

This page is the VictoriaMetrics counterpart to *stats-me-clients*(7),
which documents the UDP/statsd ingestion path (port *8125*). Most
client apps push *statsd → stats-me → graphite → VictoriaMetrics* and
only need *stats-me-clients*(7). This page is for the cases where a
caller wants to:

- query metrics out of VictoriaMetrics (dashboards, ad-hoc analysis,
  agents), or
- push to VictoriaMetrics directly without going through stats-me's
  flush cycle (e.g. high-frequency emitters, batch jobs).

# ENDPOINT DISCOVERY

When *services.stats-me-victoria-metrics.enable* is *true* AND
*services.stats-me.autowireVictoriaMetrics* is *true* (default), the
home-manager module exports the following via *home.sessionVariables*:

*STATS_ME_VICTORIA_METRICS_URL*
	Full base URL of the HTTP query endpoint, e.g.
	*http://127.0.0.1:8428*. Consumers append /api/v1/query (etc.) to
	this. Read by *stats-me-query*(1) and downstream agents.

*STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST*
	Hostname / IP for the graphite plaintext receiver. Always loopback
	for a personal install.

*STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT*
	Port for the graphite plaintext receiver. Mirrors
	*services.stats-me-victoria-metrics.graphitePort* (default *2003*).

If *services.stats-me.autowireVictoriaMetrics* is *false*, the env
vars are NOT exported even when VictoriaMetrics is enabled. This is
intentional: opting out of the autowire means the user is wiring
stats-me's graphite backend manually, and surfacing
discovery env vars would imply a wiring that isn't actually in place.

## Resolution order

For client code, the recommended resolution order mirrors the
statsd-client one:

. Explicit constructor / CLI argument
. *STATS_ME_VICTORIA_METRICS_URL* (or _GRAPHITE_HOST/_PORT_) from env
. Hard-coded fallback *http://127.0.0.1:8428* / *127.0.0.1:2003*

# QUERYING

VictoriaMetrics speaks the Prometheus HTTP API plus a few VM-specific
endpoints. Highlights:

*GET /api/v1/query?query=EXPR*
	Instant PromQL query at "now".

*GET /api/v1/query_range?query=EXPR&start=&end=&step=*
	Range PromQL query.

*GET /api/v1/series?match[]=...*
	List series matching a selector. Cheap for "what metrics exist?".

*GET /api/v1/labels*
	List label names known to the store.

*GET /api/v1/export?match[]=NAME*
	Dump raw datapoints (line-delimited JSON). Best for sanity checks.

The *stats-me-query*(1) CLI wraps the most common subset of these.

## Query examples

Shell (curl):

```
curl -s "$STATS_ME_VICTORIA_METRICS_URL/api/v1/query" \\
  --data-urlencode 'query=sum(rate(myapp_requests_total[5m]))'
```

*stats-me-query*(1):

```
stats-me-query series '.*foo.*'
stats-me-query query 'sum(myapp_requests_total)'
stats-me-query range 'rate(myapp_requests_total[1m])' 3600
```

The CLI auto-resolves *$STATS_ME_VICTORIA_METRICS_URL* with a
*http://127.0.0.1:8428* fallback. Override per-call with
*--victoria-metrics-url=URL*.

# PUSHING (graphite plaintext)

VictoriaMetrics's *-graphiteListenAddr* speaks the graphite plaintext
protocol on both TCP and UDP. One datapoint per line:

```
<metric.name> <value> <unix_timestamp>
```

Tags follow graphite's *name;tag=value;tag2=value2* convention.
VictoriaMetrics indexes the tags natively (no carbon-tagger needed).

## Push examples

Shell:

```
echo "myapp.requests 1 $(date +%s)" > /dev/udp/127.0.0.1/2003
echo "myapp.latency 42 $(date +%s)" | nc -u -w0 127.0.0.1 2003
```

Python:

```
import os, socket, time
host = os.environ.get("STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST",
                     "127.0.0.1")
port = int(os.environ.get("STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT",
                          "2003"))
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.sendto(f"myapp.requests 1 {int(time.time())}\\n".encode(),
            (host, port))
```

Go:

```
import (
    "fmt"; "net"; "os"; "time"
)

host := os.Getenv("STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST")
if host == "" { host = "127.0.0.1" }
port := os.Getenv("STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT")
if port == "" { port = "2003" }

addr, _ := net.ResolveUDPAddr("udp", net.JoinHostPort(host, port))
conn, _ := net.DialUDP("udp", nil, addr)
defer conn.Close()
fmt.Fprintf(conn, "myapp.requests 1 %d\n", time.Now().Unix())
```

# CAVEATS

*Direct graphite pushes bypass statsd aggregation.*
	stats-me's job is to aggregate UDP statsd packets into per-flush
	summaries before handing them to graphite. Pushing graphite
	plaintext directly to VictoriaMetrics skips that aggregation —
	you're sending raw datapoints. Fine for low-cardinality, low-rate
	emitters; bad for high-volume counters where stats-me's
	pre-aggregation is the whole point.

*HTTP queries are local-only by default.*
	*services.stats-me-victoria-metrics.host* defaults to *127.0.0.1*
	and binds both endpoints to loopback. Remote query callers need
	an explicit host change.

*PromQL on graphite-named metrics.*
	Metric names emitted by statsd's graphite backend use dots
	(*myapp.requests*). PromQL parsers reject literal dots in
	identifiers — query with the `{__name__="..."}` form:

	```
	{__name__="myapp.requests"}
	rate({__name__="myapp.requests"}[5m])
	```

	The *stats-me-query series* subcommand wraps this for the common
	"list everything" case.

*Empty env vars.*
	If *STATS_ME_VICTORIA_METRICS_URL* is set to an empty string,
	clients MUST treat it as unset and fall back to the loopback
	default. Same rule as *stats-me-clients(7)*'s *STATSD_HOST*.

*No env vars exported when autowire is off.*
	Set *services.stats-me.autowireVictoriaMetrics = false* to opt
	out of the env-var exports along with the graphite-backend
	wiring. Manual *--victoria-metrics-url* flags still work.

# SEE ALSO

*stats-me-clients*(7) (UDP/statsd ingestion path),
*stats-me-query*(1) (the HTTP query CLI),
*victoria-metrics*(1) (upstream documentation at
https://docs.victoriametrics.com/),
*eng-direnv*(7) for the *home.sessionVariables* loading order.
