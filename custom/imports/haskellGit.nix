# Takes the URL of a git repo containing a .cabal file (i.e. a Haskell project).
# Uses cabal2nix on the repo's HEAD.
{ url, ref ? "HEAD" }:

with builtins;
let nixpkgs = import <nixpkgs> {};
in

nixpkgs.withLatestGit {
  inherit url ref;
  srcToPkg = x: nixpkgs.nixFromCabal "${x}";
  resultComposes = true;
}
