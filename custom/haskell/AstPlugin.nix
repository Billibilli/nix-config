import ../imports/haskellGit.nix {
  url = if import ../imports/localOnly.nix
           then "/home/chris/Programming/repos/ast-plugin.git"
           else http://chriswarbo.net/git/ast-plugin.git;
}
