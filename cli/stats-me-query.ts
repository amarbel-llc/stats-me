///!dep zx@8.8.5 sha512-SNgDF5L0gfN7FwVOdEFguY3orU5AkfFZm9B5YSHog/UDHv+lvmd82ZAsOenOkQixigwH2+yyH198AwNdKhj+RA==
///
/// stats-me-query: thin CLI wrapper around VictoriaMetrics's HTTP
/// query endpoints. See stats-me-victoria-metrics-clients(7) for the
/// env-var resolution contract and broader VictoriaMetrics-client
/// guidance.
///
/// Subcommands:
///   stats-me-query series [PATTERN]      List metric names. PATTERN is a regex
///                                        matched against __name__. Default ".*".
///   stats-me-query export METRIC_NAME    Dump raw datapoints for a series via
///                                        /api/v1/export. Best for sanity checks.
///   stats-me-query query EXPR            Instant PromQL query at "now".
///   stats-me-query range EXPR [SECONDS]  Range query over the last SECONDS (default
///                                        300). Step auto-derived as max(15, SECONDS/60).
///   stats-me-query labels                List label names known to VictoriaMetrics.
///
/// Output is whatever VictoriaMetrics returned (JSON), pretty-printed via JSON.stringify.
///
/// VictoriaMetrics endpoint: $STATS_ME_VICTORIA_METRICS_URL, default http://127.0.0.1:8428
/// Override per-call via --victoria-metrics-url=URL as the first arg.

import { $ } from "zx";

// We don't shell out, so silence zx (it would print a banner).
$.verbose = false;

const DEFAULT_VICTORIA_METRICS_URL = "http://127.0.0.1:8428";

const usage = `Usage:
  stats-me-query [--victoria-metrics-url=URL] series [PATTERN]
  stats-me-query [--victoria-metrics-url=URL] export METRIC_NAME
  stats-me-query [--victoria-metrics-url=URL] query EXPR
  stats-me-query [--victoria-metrics-url=URL] range EXPR [SECONDS]
  stats-me-query [--victoria-metrics-url=URL] labels

VictoriaMetrics endpoint resolution: --victoria-metrics-url > $STATS_ME_VICTORIA_METRICS_URL > ${DEFAULT_VICTORIA_METRICS_URL}
`;

class UsageError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UsageError";
  }
}

class HelpRequested extends Error {
  constructor() {
    super("help requested");
    this.name = "HelpRequested";
  }
}

const die = (msg: string): never => {
  throw new UsageError(msg);
};

const parseArgs = (argv: string[]): { victoriaMetricsUrl: string; rest: string[] } => {
  let victoriaMetricsUrl = process.env.STATS_ME_VICTORIA_METRICS_URL ?? DEFAULT_VICTORIA_METRICS_URL;
  const rest: string[] = [];
  for (const arg of argv) {
    if (arg.startsWith("--victoria-metrics-url=")) {
      victoriaMetricsUrl = arg.slice("--victoria-metrics-url=".length);
    } else if (arg === "--help" || arg === "-h") {
      throw new HelpRequested();
    } else {
      rest.push(arg);
    }
  }
  return { victoriaMetricsUrl, rest };
};

const get = async (url: string): Promise<unknown> => {
  const r = await fetch(url);
  if (!r.ok) {
    const text = await r.text().catch(() => "");
    die(`HTTP ${r.status} from ${url}\n${text}`);
  }
  // /api/v1/export returns line-delimited JSON, not a single object.
  // We do not try to be clever — return raw text for callers that
  // care, otherwise parse JSON.
  const contentType = r.headers.get("content-type") ?? "";
  if (contentType.includes("application/stream+json")) {
    return await r.text();
  }
  return await r.json();
};

const printResult = (result: unknown) => {
  if (typeof result === "string") {
    process.stdout.write(result.endsWith("\n") ? result : result + "\n");
    return;
  }
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
};

const cmdSeries = async (victoriaMetricsUrl: string, args: string[]) => {
  const pattern = args[0] ?? ".*";
  const url = new URL("/api/v1/series", victoriaMetricsUrl);
  url.searchParams.append("match[]", `{__name__=~${JSON.stringify(pattern)}}`);
  printResult(await get(url.toString()));
};

const cmdExport = async (victoriaMetricsUrl: string, args: string[]) => {
  const metric = args[0];
  if (!metric) die("export: METRIC_NAME is required");
  const url = new URL("/api/v1/export", victoriaMetricsUrl);
  url.searchParams.append("match[]", metric);
  printResult(await get(url.toString()));
};

const cmdQuery = async (victoriaMetricsUrl: string, args: string[]) => {
  const expr = args[0];
  if (!expr) die("query: EXPR is required");
  const url = new URL("/api/v1/query", victoriaMetricsUrl);
  url.searchParams.set("query", expr);
  printResult(await get(url.toString()));
};

const cmdRange = async (victoriaMetricsUrl: string, args: string[]) => {
  const expr = args[0];
  if (!expr) die("range: EXPR is required");
  const seconds = args[1] ? Number.parseInt(args[1], 10) : 300;
  if (!Number.isFinite(seconds) || seconds <= 0) {
    die(`range: SECONDS must be a positive integer (got ${args[1]})`);
  }
  const end = Math.floor(Date.now() / 1000);
  const start = end - seconds;
  const step = Math.max(15, Math.floor(seconds / 60));
  const url = new URL("/api/v1/query_range", victoriaMetricsUrl);
  url.searchParams.set("query", expr);
  url.searchParams.set("start", String(start));
  url.searchParams.set("end", String(end));
  url.searchParams.set("step", `${step}s`);
  printResult(await get(url.toString()));
};

const cmdLabels = async (victoriaMetricsUrl: string, _args: string[]) => {
  const url = new URL("/api/v1/labels", victoriaMetricsUrl);
  printResult(await get(url.toString()));
};

const main = async () => {
  try {
    const { victoriaMetricsUrl, rest } = parseArgs(process.argv.slice(2));
    const [subcommand, ...subargs] = rest;
    if (!subcommand) {
      process.stderr.write(usage);
      process.exitCode = 1;
      return;
    }

    const handlers: Record<string, (victoriaMetricsUrl: string, args: string[]) => Promise<void>> = {
      series: cmdSeries,
      export: cmdExport,
      query: cmdQuery,
      range: cmdRange,
      labels: cmdLabels,
    };

    const handler = handlers[subcommand];
    if (!handler) die(`unknown subcommand: ${subcommand}`);

    await handler(victoriaMetricsUrl, subargs);
  } catch (err) {
    if (err instanceof HelpRequested) {
      process.stdout.write(usage);
      return;
    }
    const message = err instanceof Error ? err.message : String(err);
    process.stderr.write(`stats-me-query: ${message}\n${usage}`);
    process.exitCode = 2;
  }
};

void main();
