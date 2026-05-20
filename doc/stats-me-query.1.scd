stats-me-query(1)

# NAME

stats-me-query - thin CLI wrapper around VictoriaMetrics's HTTP query endpoints

# SYNOPSIS

*stats-me-query* [_--victoria-metrics-url=URL_] *series* [_PATTERN_]++
*stats-me-query* [_--victoria-metrics-url=URL_] *export* _METRIC_NAME_++
*stats-me-query* [_--victoria-metrics-url=URL_] *query* _EXPR_++
*stats-me-query* [_--victoria-metrics-url=URL_] *range* _EXPR_ [_SECONDS_]++
*stats-me-query* [_--victoria-metrics-url=URL_] *labels*

# DESCRIPTION

*stats-me-query* is a small Bun-runtime zx script that wraps the most
commonly-used VictoriaMetrics HTTP query endpoints behind a flat
subcommand surface. It does no aggregation or formatting beyond
JSON-pretty-printing whatever VictoriaMetrics returns; the goal is to
remove the *curl --data-urlencode* boilerplate, not to be a query
language.

The CLI auto-resolves the VictoriaMetrics endpoint from the
*STATS_ME_VICTORIA_METRICS_URL* environment variable, with a
*http://127.0.0.1:8428* fallback. See *ENVIRONMENT* and
*stats-me-victoria-metrics-clients*(7) for the full discovery
contract.

# OPTIONS

*--victoria-metrics-url*=_URL_
	Override the VictoriaMetrics base URL for this invocation. Wins
	over *STATS_ME_VICTORIA_METRICS_URL* and the hard-coded fallback.
	Must precede the subcommand. Repeatable; last wins.

*-h*, *--help*
	Print usage to stdout and exit *0*.

# SUBCOMMANDS

*series* [_PATTERN_]
	List metric names matching _PATTERN_ via */api/v1/series*.
	_PATTERN_ is a regex applied to the *\_\_name\_\_* label.
	Defaults to *.\** (everything).

*export* _METRIC_NAME_
	Dump raw datapoints for _METRIC_NAME_ via */api/v1/export*.
	Output is line-delimited JSON streamed straight through; best
	for sanity-checking what actually landed in storage.

*query* _EXPR_
	Instant PromQL query at "now" via */api/v1/query*. _EXPR_ is
	any PromQL expression.

*range* _EXPR_ [_SECONDS_]
	Range PromQL query over the last _SECONDS_ (default *300*) via
	*/api/v1/query_range*. Step is auto-derived as
	*max(15, SECONDS / 60)* seconds.

*labels*
	List label names known to VictoriaMetrics via */api/v1/labels*.

# ENVIRONMENT

*STATS_ME_VICTORIA_METRICS_URL*
	Base URL of the VictoriaMetrics HTTP query endpoint, e.g.
	*http://127.0.0.1:8428*. Exported automatically by the
	*services.stats-me-victoria-metrics* home-manager module when
	the autowire is active. See
	*stats-me-victoria-metrics-clients*(7) for the discovery
	contract.

## Resolution order

. *--victoria-metrics-url*=_URL_ on the command line
. *STATS_ME_VICTORIA_METRICS_URL* in the environment
. Hard-coded fallback *http://127.0.0.1:8428*

An empty-string *STATS_ME_VICTORIA_METRICS_URL* is treated as unset
and falls through to the default.

# EXIT STATUS

*0*
	Subcommand completed and VictoriaMetrics returned a *2xx*
	response.

*1*
	Generic runtime error (caught exception from the handler).

*2*
	Usage error: unknown subcommand, missing required argument,
	non-2xx HTTP response from VictoriaMetrics, or any other
	*die()* call.

# EXAMPLES

List every series:

```
stats-me-query series
```

List series whose names match a regex:

```
stats-me-query series '.*requests.*'
```

Instant PromQL query:

```
stats-me-query query 'sum(rate(myapp_requests_total[5m]))'
```

Range query over the last hour:

```
stats-me-query range 'rate(myapp_requests_total[1m])' 3600
```

Dump raw datapoints for one series (graphite-named, with dots — use
the *{\_\_name\_\_="..."}* form because PromQL identifiers reject
literal dots):

```
stats-me-query export 'myapp.requests'
```

Query against a non-default VictoriaMetrics URL:

```
stats-me-query --victoria-metrics-url=http://remote:8428 labels
```

# CAVEATS

*PromQL on graphite-named metrics.*
	The graphite backend emits metric names with dots
	(*myapp.requests*). PromQL parsers reject literal dots in
	identifiers, so *query* and *range* with such names need the
	*{\_\_name\_\_="..."}* form. *export* and *series* take the raw
	name and are unaffected.

*No streaming.*
	*export* returns line-delimited JSON but *stats-me-query* reads
	the whole response into memory before printing. Fine for
	personal-stats volumes; bad for large multi-month dumps.

*UDP statsd vs HTTP query.*
	*stats-me-query* talks to the HTTP query endpoint (default port
	*8428*). The UDP statsd ingestion endpoint (default port *8125*,
	the *stats-me* daemon itself) is a separate surface — see
	*stats-me-clients*(7) for that side.

# SEE ALSO

*stats-me-victoria-metrics-clients*(7) (env-var discovery, push API),
*stats-me-clients*(7) (UDP/statsd ingestion path),
*stats-me*(1) (the statsd daemon wrapper),
*victoria-metrics*(1) (upstream — https://docs.victoriametrics.com/).
