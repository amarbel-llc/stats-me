# stats-me's conformist overlay, merged with conformist.lib.presets.eng in
# flake.nix (conformist.lib.evalModule — the pure lane's eval imports this
# file; the impure lane, presets.eng-impure, is unconditional and needs no
# repo-specific overlay of its own). presets.eng enables the eng-convention
# linters (eng-versioning, flake-outputs/lock, the justfile-* roster). Here
# live nixfmt, the eng-versioning key, and repo-specific excludes.
#
# No presets.eng-go: the only Go code in this tree is the frozen
# zz-pocs/stats-me-poc/ proof-of-concept, which is excluded below — matching
# igloo's conformist.nix precedent ("exploratory proofs-of-concept; not held
# to lint standards") and stats-me's own justfile, which already says the POC
# is "intentionally not wired in ... per the eng:poc skill". Once the POC
# graduates into the real vendor/statsd-based package (see README.md
# "Status"), revisit both this exclude and eng-go.
{ ... }:
{
  # Nix: format the flake + this file + nix/hm/*.nix.
  programs.nixfmt.enable = true;

  # eng-versioning(7) would otherwise derive the key from a root-level
  # go.mod / Cargo.toml; stats-me has neither at the tree root (only
  # zz-pocs/stats-me-poc/go.mod, which is excluded below). Set the key
  # explicitly; version.env now exists (export STATS_ME_VERSION=<sem>) and
  # the check runs against it.
  linters.eng-versioning.key = "STATS_ME_VERSION";

  settings.excludes = [
    "*.md"
    "flake.lock"
    "result"
    "result-*"
    ".tmp/**"
    # Vendored upstream statsd tree — not first-party code.
    "vendor/**"
    # Exploratory proof-of-concept; not held to lint standards (see header).
    "zz-pocs/**"
  ];
}
