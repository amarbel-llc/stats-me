# stats-me — wrapper that invokes a vendored statsd via Bun.
#
# Inputs come from callPackage. The wrapper:
#   1. Copies the vendored statsd tree into $out/share/stats-me/statsd
#   2. Copies the default config into $out/share/stats-me/default-config.js
#   3. Emits $out/bin/stats-me, a tiny shell wrapper that:
#        - cd's into the statsd tree (statsd's `require()` calls are
#          relative; running from elsewhere breaks backend loading)
#        - exec's `${bun}/bin/bun stats.js <config>` where <config> is
#          $1 if set, else the bundled default-config.js
{
  lib,
  stdenvNoCC,
  bun,
  makeWrapper,
  scdoc,
  # Single source of truth: version.env (eng-versioning(7)), an
  # `export STATS_ME_VERSION=<sem>` file at repo root. default.nix is a
  # plain stdenvNoCC.mkDerivation (no buildGoApplication auto-read), so
  # the flake reads version.env at eval time and passes the value in here
  # rather than default.nix hardcoding or re-reading it itself.
  version,
}:

stdenvNoCC.mkDerivation {
  pname = "stats-me";
  inherit version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./vendor/statsd
      ./config
      ./doc
    ];
  };

  nativeBuildInputs = [
    makeWrapper
    scdoc
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/stats-me $out/share/man/man1 $out/share/man/man7
    cp -r vendor/statsd $out/share/stats-me/statsd
    cp config/default-config.js $out/share/stats-me/default-config.js

    # Build man pages from scdoc sources. Sections are inferred from
    # the filename suffix (foo.1.scd → man1/foo.1, bar.7.scd → man7/bar.7).
    for f in doc/*.scd; do
      base="$(basename "$f" .scd)"
      section="''${base##*.}"
      scdoc < "$f" > "$out/share/man/man''${section}/$base"
    done

    # Use a hand-written wrapper instead of makeWrapper: we need the
    # `cd` into the statsd dir AND argument forwarding, which
    # makeWrapper's --add-flags / --run cannot express together.
    cat > $out/bin/stats-me <<EOF
    #!${stdenvNoCC.shell}
    set -eu
    config="\''${1:-$out/share/stats-me/default-config.js}"
    cd "$out/share/stats-me/statsd"
    exec "${bun}/bin/bun" "$out/share/stats-me/statsd/stats.js" "\$config"
    EOF
    chmod +x $out/bin/stats-me

    runHook postInstall
  '';

  meta = {
    description = "stats-me: personal statsd, run under Bun";
    homepage = "https://code.linenisgreat.com/stats-me";
    license = lib.licenses.mit;
    mainProgram = "stats-me";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
