default:
    @just --list

# Pre-merge gate. Builds the package and runs flake check (which
# itself rebuilds the package via the `checks` attr — cheap enough
# given nix's caching). The POC under zz-pocs/ is intentionally not
# wired in here per the eng:poc skill.
[group('check')]
check:
    nix build .#default
    nix flake check

# Build the package only.
[group('check')]
build:
    nix build .#default

# Run the daemon ad-hoc against the bundled default config. Logs to
# stdout (no XDG redirection — the wrapper's launcher script lives
# in the home-manager module, not the package itself).
[group('explore')]
run:
    nix run .#default

# Run the proof-of-concept end-to-end. Validates Bun + statsd.
[group('explore')]
poc:
    cd zz-pocs/stats-me-poc && nix run .#stats-me-exporel
