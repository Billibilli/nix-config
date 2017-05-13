{ buildEnv, cabal-install, cabal2nix, hackageDb, haskell, haskellPackages,
  haskellTinc, latestGit, lib, runCommand, stdenv, withNix, writeScript,
  runCabal2nix }:

with builtins;
with lib;
with rec {
  defHPkg = haskellPackages;

  tincify = args:
    assert isAttrs args || abort "tincify args should be attrs";
    assert args ? src   || abort "tincify args should contain src";
    with rec {
      inherit (args) src;
      name            = args.name            or "pkg";
      haskellPackages = args.haskellPackages or defHPkg;
      pkgs            = args.pkgs            or import <nixpkgs> {};
      extras          = args.extras          or {};
      cache           = args.cache           or {
                                                  global = true;
                                                  path   = "/tmp/tincify-home";
                                                };

      # By default, tinc runs Cabal in a Nix shell with the following available:
      #
      #   haskellPackages.ghcWithPackages (p: [ p.cabal-install ])'
      #
      # This can be fiddled a bit using TINC_NIX_RESOLVER, but overall we're
      # stuck using a Haskell package set that's available globally with a
      # particular attribute path. We don't want that; we want to use the
      # Haskell package set we've been given (haskellPackages), which might not
      # be available globally.
      #
      # To make tinc use this version, we rely on the fact it's only using
      # cabal-install, as above. We build that derivation, using our Haskell
      # package set, write it to disk, then set NIX_PATH such that tinc's
      # nix-shell invocation uses the derivation we built. Phew!
      toUse = buildEnv {
        name  = "tinc-env";
        paths = [ (haskellPackages.ghcWithPackages (p: [ p.cabal-install ])) ];
      };

      env = runCommand "tinc-env"
        {
          expr = writeScript "force-tinc-env.nix" ''
            _:
              import <real> {} // {
              haskellPackages = {
                ghcWithPackages = _:
                  ${toUse};
              };
            }
          '';
        }
        ''
          mkdir -p "$out/pkgs/build-support/fetchurl"
          cp "$expr" "$out/default.nix"
          cp "${<nixpkgs/pkgs/build-support/fetchurl/mirrors.nix>}" \
             "$out/pkgs/build-support/fetchurl/mirrors.nix"
        '';

      NIX_PATH = concatStringsSep ":" [
        "nixpkgs=${env}"
        "real=${(head (filter (p: p.prefix == "nixpkgs")
                              nixPath)).path}"
      ];

      hackageUpdate = path: runCommand "hackage-update"
        {
          inherit hackageDb;
          buildInputs = [ cabal-install ];
          HOME        = path;
        }
        ''
          # Whenever hackageDb expires, update HOME too
          [[ -d "$HOME" ]] || mkdir -p "$HOME"
          cabal update

          # Allow access to subsequent builders. Existing stuff may be owned by
          # others, which causes a bunch of errors. This is non-critical so we
          # ignore them all.
          chmod 777 -R "$HOME" 2>/dev/null || true

          # Maybe help debugging by knowing when we updated
          date > "$out"
        '';

      defs = runCommand "tinc-of-${name}"
               (withNix {
                 inherit src;

                 buildInputs = [
                   (haskell.packages.ghc802.callPackage (runCabal2nix {
                     url = latestGit {
                       url = "http://chriswarbo.net/git/tinc.git";
                     };
                   }) {})
                   #haskellTinc
                   (haskellPackages.ghcWithPackages (h: [
                     h.ghc
                     h.cabal-install
                   ]))
                   cabal2nix
                 ];

                 TINC_USE_NIX = "yes";

                 # If we're using a global cache, forces it to be updated at the
                 # same rate as hackageDb. If we're not, this does nothing.
                 cacheDep = if cache.global
                               then hackageUpdate cache.path
                               else runCommand "nothing" {} ''mkdir "$out"'';

                 # Should we share an impure cache with prior/subsequent calls?
                 GLOBALCACHE = if cache.global then "true" else "false";

                 # Where to find cached data; when global this should be a
                 # string like "/tmp/foo". Non-global might be e.g. a path, or a
                 # derivation.
                 CACHEPATH = assert cache.global -> isString cache.path ||
                             abort ''Global cache path should be a string, to
                                     prevent Nix copying it to the store.'';
                             cache.path;

               } // { inherit NIX_PATH; /*Overrides withNix */ })
               ''
                 function allow {
                   # Allows subsequent users to read/write our cached values
                   # Note that we ignore errors because we may not own some of
                   # the existing files.
                   chmod 777 -R "$HOME" 2>/dev/null || true
                 }

                 if $GLOBALCACHE
                 then
                   # Use the cache in-place
                   export HOME="$CACHEPATH"
                 else
                   # Use a mutable copy of the given cache
                   cp -r "$CACHEPATH" ./cache
                   allow
                   export HOME="$PWD/cache"
                 fi

                 # Force cache creation, e.g. if a global cache has been deleted
                 [[ -d "$HOME" ]] || {
                   echo "Cache dir '$HOME' not found, initialising" 1>&2
                   mkdir -p "$HOME"
                   cabal update
                   allow
                 }

                 if [[ -d "$src" ]]
                 then
                   cp -r "$src" ./src
                 else
                   echo "Assuming $src is a tarball" 1>&2
                   mkdir ./src
                   # Extract top-level directory (whatever it's called) to ./src
                   tar xf "$src" -C ./src --strip-components 1
                 fi
                 chmod +w -R ./src

                 pushd ./src; tinc; popd
                 allow

                 cp -r ./src "$out"
               '';

      deps = import "${defs}/tinc.nix" {
        inherit haskellPackages;
        nixpkgs = pkgs;
      };

      overrides = self: super: deps.packages {
        callPackage = stdenv.lib.callPackageWith
          (pkgs // pkgs.xorg // pkgs.gnome2 // self // extras);
      };

      resolver = haskellPackages.override { inherit overrides; };

      result = resolver.callPackage "${defs}/package.nix" {};
    };
    result;
};
tincify
