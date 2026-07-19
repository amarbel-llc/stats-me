default: lint build test

lint: lint-fmt

# Read-only formatting + the eng preset's file-based linters, via the
# sandboxed checks.formatting derivation.
[group('lint')]
lint-fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
    nix build ".#checks.${system}.formatting" --no-link --print-build-logs

lint-impure: lint-worktree

# The impure eng checks (git remotes, sweatfile, agents-md) against the
# working tree, where .git is available. Runs conformist from the devShell
# (direnv `use flake`).
[group('lint')]
lint-worktree:
    #!/usr/bin/env bash
    set -euo pipefail
    cfg=$(nix build --no-link --print-out-paths '.#conformist-impure-config')
    conformist check --config-file "$cfg" --tree-root .

build: build-nix

# Build the package via nix.
[group('build')]
build-nix:
    nix build .#default

test: test-flake

# Run flake check (rebuilds package via the `checks` attr — cheap
# given nix's caching). The POC under zz-pocs/ is intentionally not
# wired in here per the eng:poc skill.
[group('test')]
test-flake:
    nix flake check

run: run-nix

# Run the daemon ad-hoc against the bundled default config. Logs to
# stdout (no XDG redirection — the wrapper's launcher script lives
# in the home-manager module, not the package itself).
[group('run')]
run-nix:
    nix run .#default

# Run the proof-of-concept end-to-end via cross-justfile delegation.
[group('run')]
run-poc:
    just zz-pocs/stats-me-poc/run-nix

codemod: codemod-fmt

# Format the tree in place (repair mode) via `nix fmt`.
[group('codemod')]
codemod-fmt:
    nix fmt
