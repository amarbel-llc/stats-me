# stats-me

Personal statsd, run under [Bun](https://bun.sh), packaged as a
home-manager / nix-darwin module.

## Status

Pre-implementation. Only the proof-of-concept exists today, in
[`zz-pocs/stats-me-poc/`](zz-pocs/stats-me-poc/). The production
flake, package, and home-manager module are not yet built.

## Goal

A drop-in module for `~/eng`-style nix configurations that exposes
`services.stats-me`, runs a statsd daemon under launchd (macOS) or
systemd (Linux), defaults to the console backend with logs at the
XDG-spec path (`$XDG_LOG_HOME/stats-me/stats-me.log`,
defaulting to `$HOME/.local/log/stats-me/stats-me.log`), and lets the
user point at any pluggable backend later.

## POC findings

The POC validates one hypothesis: Bun can run upstream `statsd/statsd`
and receive UDP packets on macOS.

- ✅ Bun (1.3.11) executes `statsd/statsd` `stats.js` unmodified
- ✅ The vendored statsd tree under `zz-pocs/stats-me-poc/vendor/statsd`
  needs no `bun install` — the optional native deps are not exercised
  by the console backend
- ⚠️ Bun's `'listening'` event is not a true readiness signal: the very
  first UDP packet sent immediately after `bind()` is silently dropped.
  Subsequent packets work. Tests must spam or retry; production clients
  are UDP-loss-tolerant by design
- ⚠️ `nixos-25.11` ships `bun-1.3.3`, which has worse macOS dgram
  problems. The POC fetches `bun-1.3.11` directly from upstream
  releases via a `fetchurl` FOD. Production will need the same
  approach (or a real package once the toolchain catches up)

The full architecture plan, decision log, and verification gates live
in this session's planning notes; once implementation begins, design
notes will land under `docs/`.

## Layout (planned)

```
.
├── flake.nix              # inputs + outputs
├── default.nix            # mkBunDerivation entry point
├── nix/hm/stats-me.nix    # home-manager module
├── config/                # default config(s), e.g. console backend
├── vendor/statsd/         # vendored upstream statsd tree (graduated from POC)
└── zz-pocs/stats-me-poc/  # frozen POC, kept for future debugging
```

## License

MIT for the stats-me wrapper code. The vendored `statsd` tree retains
its upstream MIT license — see `vendor/statsd/LICENSE`.
