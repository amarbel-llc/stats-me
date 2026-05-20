stats-me-clients(7)

# NAME

stats-me-clients - sending metrics to a stats-me daemon

# DESCRIPTION

*stats-me* is upstream *statsd*(1) packaged under Bun. Clients send
metrics by emitting UDP datagrams in the statsd wire format to the
listener address. There is no library API and no auth — anything that
can write UDP can publish metrics.

This page documents the endpoint, port-discovery convention, wire
format, and language examples. For daemon configuration, see the
*services.stats-me* options in the home-manager module
(_nix/hm/stats-me.nix_ in the *stats-me* flake).

# ENDPOINT

UDP, one metric per packet (or _\\n_-separated batches, statsd convention
limited by your client lib and MTU).

The daemon binds the port given by *services.stats-me.port* (default
*8125*). statsd's *config.address* is left unset, so the underlying
*dgram.bind* listens on all interfaces — *0.0.0.0:8125* in practice for
a default install. Clients on the same host connect via *127.0.0.1*.

# PORT DISCOVERY

stats-me follows the de-facto statsd-ecosystem environment variable
convention. When *services.stats-me.enable = true*, the home-manager
module exports the following via *home.sessionVariables*:

*STATSD_HOST*
	Hostname or IP the clients should connect to. Always *127.0.0.1*
	for a personal, loopback-only stats-me. If clients see *STATSD_HOST*
	empty or unset, they MUST default to *127.0.0.1*.

*STATSD_PORT*
	UDP port. Mirrors *services.stats-me.port* (default *8125*).

Most statsd client libraries pick these up automatically:

- *hot-shots* (Node) — reads *STATSD_HOST*, *STATSD_PORT* when the
  constructor is called with no host/port override.
- *python-statsd*, *statsd* (Python) — same env vars.
- *cactus/go-statsd-client* (Go) — same.
- *cadence* (Rust) — uses *STATSD_HOST* / *STATSD_PORT* via its
  *UdpMetricSink::from* helper when no explicit address is passed.

Clients that don't auto-detect can read the env vars themselves and
fall back to *127.0.0.1:8125*.

## Resolution order

For client code, the recommended resolution order is:

. Explicit constructor argument
. *STATSD_HOST* / *STATSD_PORT* environment
. Hard-coded fallback *127.0.0.1:8125*

# WIRE FORMAT

```
<metric.name>:<value>|<type>[|@<sample_rate>][|#<tag>:<value>,...]
```

*type*
	One of:
	- *c* counter (integer increment)
	- *g* gauge (absolute value; prefix with _+_ or _-_ for delta)
	- *ms* timer (milliseconds; statsd computes percentiles)
	- *h* histogram (alias of *ms* in core statsd)
	- *s* set (count of unique values)

*sample_rate*
	Optional float in (0, 1]. The client emits a fraction of samples;
	statsd scales the aggregate. Use for high-volume counters.

*tags*
	Optional DogStatsD-style key/value tags. Backend support varies;
	the console backend ignores them, the graphite backend embeds them
	into the metric name path depending on backend config.

# EXAMPLES

## Shell

```
echo "myapp.requests:1|c" | nc -u -w0 127.0.0.1 8125
echo "myapp.latency:42|ms" > /dev/udp/127.0.0.1/8125
```

The second form is a bash builtin, no *nc* needed.

## Node (hot-shots)

```
import StatsD from "hot-shots";

// Reads STATSD_HOST / STATSD_PORT from env when no args given.
const stats = new StatsD();
stats.increment("myapp.requests");
stats.timing("myapp.latency", 42);
```

## Python (python-statsd)

```
import statsd
# StatsClient() picks up STATSD_HOST / STATSD_PORT from env.
c = statsd.StatsClient()
c.incr("myapp.requests")
c.timing("myapp.latency", 42)
```

## Go (cactus/go-statsd-client)

```
import "github.com/cactus/go-statsd-client/v5/statsd"

cfg := &statsd.ClientConfig{
    Address: os.Getenv("STATSD_HOST") + ":" + os.Getenv("STATSD_PORT"),
    Prefix:  "myapp",
}
c, _ := statsd.NewClientWithConfig(cfg)
defer c.Close()
c.Inc("requests", 1, 1.0)
```

## Rust (cadence)

```
use cadence::{StatsdClient, UdpMetricSink};
use std::net::UdpSocket;

let host = std::env::var("STATSD_HOST")
    .unwrap_or_else(|_| "127.0.0.1".into());
let port: u16 = std::env::var("STATSD_PORT")
    .ok().and_then(|s| s.parse().ok()).unwrap_or(8125);

let socket = UdpSocket::bind("0.0.0.0:0").unwrap();
let sink = UdpMetricSink::from((host.as_str(), port), socket).unwrap();
let client = StatsdClient::from_sink("myapp", sink);
client.incr("requests").ok();
```

# CAVEATS

*UDP is fire-and-forget.*
	No delivery guarantee, no backpressure, no error if the daemon is
	down. Use stats-me for telemetry, never for billing-critical
	counters.

*First packet after daemon start can be dropped.*
	Under Bun, statsd's *listening* event is not a true readiness
	signal — the very first UDP datagram immediately after *bind()* is
	silently lost. Subsequent packets work. Production clients are UDP
	loss-tolerant by design; synthetic tests must retry or spam.

*Default bind is all-interfaces.*
	statsd's *config.address* is unset in stats-me's default config, so
	the daemon listens on *0.0.0.0:8125*. On multi-user or
	publicly-routable machines, set *services.stats-me.extraConfig.address
	= "127.0.0.1"* (or use *configFile* for full control). The
	*STATSD_HOST* export is always *127.0.0.1* regardless — clients
	connect over loopback.

*Empty STATSD_HOST.*
	If the env var is set to an empty string (e.g. by a process that
	clears env between fork and exec), clients MUST treat it as unset
	and default to *127.0.0.1*. Do not pass an empty string to
	*getaddrinfo*; behaviour is platform-specific.

# SEE ALSO

*statsd*(1) (upstream documentation at https://github.com/statsd/statsd),
*stats-me*(1) (the daemon wrapper script — _bin/stats-me_ in this
package), *eng-direnv*(7) for the *home.sessionVariables* loading
order.
