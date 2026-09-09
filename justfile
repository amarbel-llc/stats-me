default: lint build test

lint: lint-fmt

# Read-only formatting + the eng preset's file-based linters, via the
# sandboxed checks.formatting derivation.
#
# check formatting and the eng file-based lints, read-only
[group('lint')]
lint-fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
    nix build ".#checks.${system}.formatting" --no-link --print-build-logs

# Lint the rendered man pages (built by default.nix from doc/*.scd):
# each page's NAME entry must be exactly one physical roff line that
# lexgrog parses, with a description of at most 72 characters. spinclass
# renders only the first roff line of NAME into its sysprompt index, so
# a hand-wrapped NAME paragraph shows up there truncated (fleet rule:
# doppelgang lint-man). Requires lexgrog (man-db) on PATH.
#
# check man page NAME lines are single-line, <= 72 chars, lexgrog-parseable
[group('lint')]
lint-man:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(nix build --no-link --print-out-paths .#default)
    status=0
    for page in "$out"/share/man/man*/*; do
        # fixupPhase gzips the pages; zcat -f also passes plain files through.
        lines=$(zcat -f "$page" | awk '/^\.SH NAME/{inname=1; next} /^\.SH/{inname=0} inname && !/^\./{n++} END{print n+0}')
        if [ "$lines" -ne 1 ]; then
            echo "FAIL: $(basename "$page"): NAME spans $lines physical lines (want 1)" >&2
            status=1
        fi
        if ! whatis=$(lexgrog "$page"); then
            echo "FAIL: $(basename "$page"): lexgrog cannot parse NAME" >&2
            status=1
            continue
        fi
        desc=${whatis#* - }
        desc=${desc%\"}
        if [ -z "$desc" ] || [ "${#desc}" -gt 72 ]; then
            echo "FAIL: $(basename "$page"): description is ${#desc} chars (want 1..72): $desc" >&2
            status=1
        fi
        echo "$whatis"
    done
    exit "$status"

lint-impure: lint-worktree

# The impure eng checks (git remotes, sweatfile, agents-md) against the
# working tree, where .git is available. Runs conformist from the devShell
# (direnv `use flake`).
#
# run the impure eng checks against the working tree
[group('lint')]
lint-worktree:
    #!/usr/bin/env bash
    set -euo pipefail
    cfg=$(nix build --no-link --print-out-paths '.#conformist-impure-config')
    conformist check --config-file "$cfg" --tree-root .

build: build-nix

# build the package via nix
[group('build')]
build-nix:
    nix build .#default

test: test-flake

# Run flake check (rebuilds package via the `checks` attr — cheap
# given nix's caching). The POC under zz-pocs/ is intentionally not
# wired in here per the eng:poc skill.
#
# run nix flake check
[group('test')]
test-flake:
    nix flake check

run: run-nix

# Run the daemon ad-hoc against the bundled default config. Logs to
# stdout (no XDG redirection — the wrapper's launcher script lives
# in the home-manager module, not the package itself).
#
# run the daemon ad-hoc against the bundled default config
[group('run')]
run-nix:
    nix run .#default

# run the proof-of-concept end-to-end via cross-justfile delegation
[group('run')]
run-poc:
    just zz-pocs/stats-me-poc/run-nix

codemod: codemod-fmt

# format the tree in place (repair mode) via `nix fmt`
[group('codemod')]
codemod-fmt:
    nix fmt
