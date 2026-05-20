default: build test

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
