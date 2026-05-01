# stats-me moxy moxin

**Date:** 2026-05-01
**Status:** proposed

## Context

stats-me now ships a `stats-me-query` zx CLI that wraps VictoriaMetrics's
HTTP API. The natural next step is exposing those subcommands as MCP
tools through moxy, so agents can read personal-stats time-series the
same way they currently read git state, GitHub issues, or man pages.

This plan sketches the moxin shape — implementation lands in a follow-up.

## Audience

Agents (Claude, etc.) interacting with the user's personal stats-me
instance. Read-only access. Same machine; no auth needed since VM listens
on `127.0.0.1` by default.

## Where the moxin lives

stats-me ships its OWN moxin under `moxins/stats-me/` in this repo, NOT
in the moxy repo itself. Moxy's runtime resolves moxins from
`MOXIN_PATH`-listed dirs at startup, and `mkBunMoxin`-shaped helpers
already exist for stats-me-shaped repos to package their own moxins as
nix derivations. This keeps moxy's tree from accumulating per-tool
moxins it doesn't own.

Layout:

```
moxins/stats-me/
├── _moxin.toml           # moxin manifest
├── series.toml
├── export.toml
├── query.toml
├── range.toml
└── labels.toml
```

The actual command for each tool is `@BIN@/stats-me-query <subcommand>`,
where `@BIN@` resolves to the stats-me-query derivation's `bin/` dir at
build time.

## Tool surface

Mirrors `stats-me-query`'s subcommands one-to-one:

| Tool name | CLI mapping | Required args | Optional args |
|---|---|---|---|
| `stats-me.series` | `stats-me-query series PATTERN` | — | `pattern` (default `.*`) |
| `stats-me.export` | `stats-me-query export METRIC` | `metric` | — |
| `stats-me.query` | `stats-me-query query EXPR` | `expr` | — |
| `stats-me.range` | `stats-me-query range EXPR SECONDS` | `expr` | `seconds` (default 300) |
| `stats-me.labels` | `stats-me-query labels` | — | — |

All five are `read-only-hint = true`, `idempotent-hint = true`. The
`open-world-hint` is true because they hit a network endpoint (even
though it's local).

The `@BIN@/stats-me-query` invocation reads `STATS_ME_VM_URL` from the
process env. The HM module sets this when stats-me-vm is enabled, so
the moxin works correctly under nix-darwin / home-manager. Standalone
installs (homebrew install path) get the default `http://127.0.0.1:8428`.

### Example tool TOML (`series.toml`)

```toml
schema = 3
perms-request = "always-allow"
description = "List metric names known to VictoriaMetrics. PATTERN is a regex matched against __name__."
command = "@BIN@/stats-me-query"
arg-order = ["__subcommand__", "pattern"]
result-type = "text"

[input]
type = "object"
required = []

[input.properties.pattern]
type = "string"
description = "Regex matched against the metric __name__ (default '.*')."

[annotations]
read-only-hint = true
idempotent-hint = true
open-world-hint = true
```

Caveat: `arg-order` doesn't naturally express "always pass `series` as
the first positional, then user args." Two options:

1. **Wrap with a per-subcommand binary.** stats-me's `default.nix` adds
   `bin/stats-me-query-series`, `bin/stats-me-query-export`, etc.,
   each a one-line shell wrapper that calls `stats-me-query series
   "$@"`. Cleaner moxin TOMLs, more bin scripts.

2. **Add a `prefix-args` field to the moxin schema.** Bigger lift —
   moxy schema change. Avoid.

3. **Single TOML per subcommand, hand-written `command` paths.** TOML
   declares `command = "@BIN@/stats-me-query"` and `arg-prefix =
   ["series"]`. Inspecting moxy's TOML loader to see if `arg-prefix`
   already exists would be the first step before designing this.

Default to option (1) until investigation shows option (3) is cheap.

## Packaging shape

```nix
# in stats-me/flake.nix outputs:
stats-me-moxin = bun2nix.mkBunMoxin {
  name = "stats-me";
  src = ./moxins/stats-me;
  bins = [ stats-me-query ];  # or per-subcommand wrappers per option (1)
};
```

`mkBunMoxin` doesn't currently take a `bins` arg — it builds bun
applications from .ts files. We have two paths:

- **Use `mkMoxin` instead of `mkBunMoxin`.** `mkMoxin` is the simpler
  helper for moxins whose binaries are pre-built (not a bun source
  tree). stats-me-query is already packaged via `buildZxScriptFromFile`
  outside the moxy ecosystem; `mkMoxin` would just symlink the
  binaries and the TOMLs together.
- **Add a new `mkPrebuiltMoxin` helper** to moxy that takes a list of
  pre-built binary derivations + a TOML dir. Cleaner but a moxy PR.

Lean on `mkMoxin` since stats-me-query is already a working derivation.

## Wiring into the user's session

Two paths:

1. **Add `moxins/stats-me/` to `MOXIN_PATH` in the HM module.** When
   `services.stats-me.enableMoxin = true` (new option, default false),
   set `home.sessionVariables.MOXIN_PATH = "$MOXIN_PATH:${stats-me-moxin}/share/moxy/moxins"`.
   Cleanest user surface.
2. **Document the path manually.** README says "add to your moxy
   config: ...". User-friendly enough for an internal tool.

Default (1) once the moxin actually exists; (2) is the docs we ship now.

## Open questions

- **Does stats-me-query's empty-on-cold-start behaviour leak into the
  moxin?** When a user asks "what stats are tracked?" and VM hasn't
  flushed yet, the moxin returns empty arrays. Is that a usability
  problem? Probably acceptable — agents can retry — but worth noting.
- **Should the moxin auto-discover `STATS_ME_VM_URL`?** Reading the
  HM module's effective port via a XDG file (`$XDG_RUNTIME_DIR/stats-me-vm.url`
  written by the launcher) would make the moxin work without the env
  var. Adds complexity to both the launcher and the moxin. Punt
  unless someone runs stats-me-vm on a non-default port.
- **How does this interact with the eng:integration issue (#61)?** The
  integration issue doesn't mention the moxin. Two options:
    - Add a checkbox to that issue: "MOXIN_PATH wiring".
    - Separate issue: "Wire stats-me moxin into clown's plugin loader".
  Latter is cleaner; that integration is in clown not eng.

## Out of scope

- Write tools (e.g. `stats-me.delete-series`). Read-only for now.
- Auth / multi-host VM. The moxin assumes a single local VM.
- Graphite query API (`/render?target=...&format=json`). PromQL via
  the existing surface is enough.
- Caching / response limiting. VM responses for a personal-stats setup
  are small enough that the moxin can pass them through verbatim.

## Verification gates

When the moxin is built:

1. `moxy serve-moxin stats-me` exits 0 and lists the five tools when
   queried via `tools/list`.
2. `moxy stats-me.labels` (via the proxy) returns `["__name__"]`
   against an empty VM.
3. With a UDP packet sent to stats-me beforehand, `stats-me.export`
   returns a non-empty JSON line for `stats.counters.foo.count`.
4. `tools/call` schema validation rejects a missing `expr` to the
   `query` tool.

## References

- `cli/stats-me-query.ts` — the CLI being wrapped
- `~/eng/repos/moxy/moxins/conch/_moxin.toml` — minimal moxin shape
- `~/eng/repos/moxy/moxins/sisyphus/search.toml` — example of an HTTP-
  shaped tool with required + optional inputs
- `~/eng/repos/moxy/docs/plans/2026-04-13-standalone-moxin-installer-design.md`
  — `@BIN@` substitution semantics and how brew-installable moxins
  differ from nix-built ones
- `~/eng/repos/moxy/flake.nix` — `mkMoxin`, `mkBunMoxin`,
  `mkBrewBunMoxin` definitions
