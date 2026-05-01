default:
    @just --list

# Pre-merge gate. Empty until the production flake lands; the POC
# under zz-pocs/ is intentionally not wired in here per the eng:poc
# skill ("Do not wire POC tests into the main `test` recipe").
[group('check')]
check:
    @echo "no checks yet — production flake pending"

# Run the proof-of-concept end-to-end. Validates Bun + statsd.
[group('explore')]
poc:
    cd zz-pocs/stats-me-poc && nix run .#stats-me-exporel
