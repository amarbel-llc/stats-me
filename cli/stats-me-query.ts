///!dep zx@8.8.5 sha512-SNgDF5L0gfN7FwVOdEFguY3orU5AkfFZm9B5YSHog/UDHv+lvmd82ZAsOenOkQixigwH2+yyH198AwNdKhj+RA==
///
/// stats-me-query: thin CLI wrapper around VictoriaMetrics's HTTP
/// query endpoints.
///
/// Subcommands:
///   stats-me-query series [PATTERN]      List metric names. PATTERN is a regex
///                                        matched against __name__. Default ".*".
///   stats-me-query export METRIC_NAME    Dump raw datapoints for a series via
///                                        /api/v1/export. Best for sanity checks.
///   stats-me-query query EXPR            Instant PromQL query at "now".
///   stats-me-query range EXPR [SECONDS]  Range query over the last SECONDS (default
///                                        300). Step auto-derived as max(15, SECONDS/60).
///   stats-me-query labels                List label names known to VM.
///
/// Output is whatever VM returned (JSON), pretty-printed via JSON.stringify.
///
/// VM endpoint: $STATS_ME_VM_URL, default http://127.0.0.1:8428
/// Override per-call via --vm-url=URL as the first arg.

import { $ } from "zx";

// We don't shell out, so silence zx (it would print a banner).
$.verbose = false;

const DEFAULT_VM_URL = "http://127.0.0.1:8428";

const usage = `Usage:
  stats-me-query [--vm-url=URL] series [PATTERN]
  stats-me-query [--vm-url=URL] export METRIC_NAME
  stats-me-query [--vm-url=URL] query EXPR
  stats-me-query [--vm-url=URL] range EXPR [SECONDS]
  stats-me-query [--vm-url=URL] labels

VM endpoint resolution: --vm-url > $STATS_ME_VM_URL > ${DEFAULT_VM_URL}
`;

const die = (msg: string): never => {
  process.stderr.write(`stats-me-query: ${msg}\n${usage}`);
  process.exit(2);
};

const parseArgs = (argv: string[]): { vmUrl: string; rest: string[] } => {
  let vmUrl = process.env.STATS_ME_VM_URL ?? DEFAULT_VM_URL;
  const rest: string[] = [];
  for (const arg of argv) {
    if (arg.startsWith("--vm-url=")) {
      vmUrl = arg.slice("--vm-url=".length);
    } else if (arg === "--help" || arg === "-h") {
      process.stdout.write(usage);
      process.exit(0);
    } else {
      rest.push(arg);
    }
  }
  return { vmUrl, rest };
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

const cmdSeries = async (vmUrl: string, args: string[]) => {
  const pattern = args[0] ?? ".*";
  const url = new URL("/api/v1/series", vmUrl);
  url.searchParams.append("match[]", `{__name__=~${JSON.stringify(pattern)}}`);
  printResult(await get(url.toString()));
};

const cmdExport = async (vmUrl: string, args: string[]) => {
  const metric = args[0];
  if (!metric) die("export: METRIC_NAME is required");
  const url = new URL("/api/v1/export", vmUrl);
  url.searchParams.append("match[]", metric);
  printResult(await get(url.toString()));
};

const cmdQuery = async (vmUrl: string, args: string[]) => {
  const expr = args[0];
  if (!expr) die("query: EXPR is required");
  const url = new URL("/api/v1/query", vmUrl);
  url.searchParams.set("query", expr);
  printResult(await get(url.toString()));
};

const cmdRange = async (vmUrl: string, args: string[]) => {
  const expr = args[0];
  if (!expr) die("range: EXPR is required");
  const seconds = args[1] ? Number.parseInt(args[1], 10) : 300;
  if (!Number.isFinite(seconds) || seconds <= 0) {
    die(`range: SECONDS must be a positive integer (got ${args[1]})`);
  }
  const end = Math.floor(Date.now() / 1000);
  const start = end - seconds;
  const step = Math.max(15, Math.floor(seconds / 60));
  const url = new URL("/api/v1/query_range", vmUrl);
  url.searchParams.set("query", expr);
  url.searchParams.set("start", String(start));
  url.searchParams.set("end", String(end));
  url.searchParams.set("step", `${step}s`);
  printResult(await get(url.toString()));
};

const cmdLabels = async (vmUrl: string, _args: string[]) => {
  const url = new URL("/api/v1/labels", vmUrl);
  printResult(await get(url.toString()));
};

const main = async () => {
  const { vmUrl, rest } = parseArgs(process.argv.slice(2));
  const [subcommand, ...subargs] = rest;
  if (!subcommand) {
    process.stderr.write(usage);
    process.exit(1);
  }

  const handlers: Record<string, (vm: string, args: string[]) => Promise<void>> = {
    series: cmdSeries,
    export: cmdExport,
    query: cmdQuery,
    range: cmdRange,
    labels: cmdLabels,
  };

  const handler = handlers[subcommand];
  if (!handler) die(`unknown subcommand: ${subcommand}`);

  try {
    await handler(vmUrl, subargs);
  } catch (err) {
    die(`${(err as Error).message ?? err}`);
  }
};

void main();
