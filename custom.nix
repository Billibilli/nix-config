defaultVersion:

with builtins;
with rec {
  # Various immutable versions of nixpkgs
  nixpkgs = import ./nixpkgs.nix;

  inherit (nixpkgs.nixpkgs1603) lib;

  # Just the nixpkgs repos (ignores instantiated package sets, functions, etc.)
  repos = lib.filterAttrs (name: _: lib.hasPrefix "repo" name)
                          nixpkgs;

  nixFiles = with { dir = ./custom; };
    map (f: dir + "/${f}")
        (filter (lib.hasSuffix ".nix")
                (attrNames (readDir dir)));

  custom = version: pkgs:
    with rec {
      super = nixpkgs // pkgs // { inherit customised; };

      mkPkg = x: oldPkgs:
        with { newPkgs = oldPkgs // import x self super; };
        newPkgs // {
          # Keep a record of which packages are custom
          customPkgNames = attrNames newPkgs;
        };

      self      = super // overrides;
      overrides = lib.fold mkPkg { stable = version != "unstable"; } nixFiles;
    };
    nixpkgs // overrides;

  call = repo: version: import repo {
    config = other // {
      packageOverrides = custom version;
    };
  };

  # Load each "repoFOO", applying our overrides and renaming to "nixpkgsFOO"
  customised = (lib.mapAttrs'
                 (name: repo:
                   with {
                     packagesVersion = lib.removePrefix "repo" name;
                   };
                   {
                     name  = "nixpkgs" + lib.removePrefix "repo" name;
                     value = call repo true;
                   })
                 repos) // {
                   unstable = call <nixpkgs> "unstable";
                 };

  other = import ./other.nix;
};
other // {
  packageOverrides = pkgs: nixpkgs // (getAttr defaultVersion customised) // {
    inherit customised;

    unstable = pkgs;
  };
}
