{ lib, makeWrapper, python, runCommand, withArgsOf, withDeps, writeScript }:

with builtins;
with lib;
with rec {
  checks = varChk // depChk;

  # Make sure that derivations given as paths and vars aren't forced during
  # evaluation (only at build time)
  depChk =
    with {
      script = wrap {
        vars = {
          broken1 = runCommand "broken1" {} "exit 1";
        };

        paths = [ (runCommand "broken2" {} "exit 1") ];

        script = "exit 1";
      };
    };
    {
      brokenDepsNotForced = runCommand "checkBrokenDepsNotForced"
        {
          val = if isString script.buildCommand then "true" else "false";
        }
        ''
          if "$val"
          then
            echo "pass" > "$out"
            exit 0
          fi
          exit 1
        '';
    };

  # Try a bunch of strings with quotes, spaces, etc. and see if they survive
  varChk = mapAttrs (n: v: runCommand "wrap-escapes-${n}"
                             {
                               cmd = wrap rec {
                                 vars   = { "${n}" = v; };
                                 name   = "check-wrap-escaping-${n}";
                                 paths  = [ python ];
                                 script = ''
                                   #!/usr/bin/env python
                                   from os import getenv

                                   n   = '${n}'
                                   v   = """${v}"""
                                   msg = "'{0}' was '{1}' not '{2}'"
                                   env = getenv(n)

                                   assert env == v, msg.format(n, env, v)

                                   print 'true'
                                 '';
                               };
                             }
                             ''"$cmd" > "$out"'')
                    {
                      SIMPLE = "simple";
                      SPACES = "with some spaces";
                      SINGLE = "withA'Quote";
                      DOUBLE = ''withA"Quote'';
                      MEDLEY = ''with" all 'of the" above'';
                    };

  wrap = { paths ? [], vars ? {}, file ? null, script ? null, name ? "wrap" }:
    assert file != null || script != null ||
           abort "wrap needs 'file' or 'script' argument";
    with rec {
      f = if file == null then writeScript name script else file;

      # Store each path in a variable pathVarN
      pathArgs = foldl' (rest: path: {
                          count = rest.count + 1;
                          args  = rest.args // {
                            "pathVar${toString rest.count}" = path;
                          };
                        })
                        { count = 1; args = {}; }
                        paths;

      # Store each name in a variable varNameN and the corresponding value in a
      # variable varVarN
      varArgs = foldl' (rest: name: {
                         count = rest.count + 1;
                         names = rest.names // {
                           "varName${toString rest.count}" = name;
                         };
                         args  = rest.args // {
                           "varVar${toString rest.count}" = getAttr name vars;
                         };
                       })
                       { count = 1; names = {}; args = {}; }
                       (attrNames vars);
    };
    runCommand name
      (pathArgs.args // varArgs.args // varArgs.names // {
        inherit f;
        pathCount   = length paths;
        varCount    = length (attrNames vars);
        buildInputs = [ makeWrapper ];
      })
      ''
        ARGS=()

        echo "Getting paths" 1>&2
        for N in $(seq 1 "$pathCount")
        do
          # Use a "variable variable" to look up "$pathVar$N" as a variable name
           ARG="pathVar$N"
          ARGS=("''${ARGS[@]}" "--prefix" "PATH" ":" "''${!ARG}/bin")
        done

        echo "Getting vars" 1>&2
        for N in $(seq 1 "$pathCount")
        do
          # Use "variable variables" like with paths, but for the name and value
          NAME="varName$N"
           ARG="varVar$N"

          # makeWrapper doesn't escape properly, so spaces, quote marks, dollar
          # signs, etc. will cause errors. Given a value FOO, makeWrapper will
          # write out a script containing "FOO" (i.e. it wraps the text in
          # double quotes). Double quotes aren't safe in Bash, since they splice
          # in variables for dollar signs, etc. Plus, makeWrapper isn't actually
          # doing any escaping: if our text contains a ", then it will appear
          # verbatim and break the surrounding quotes.
          # To work around this we do the following:
          #  - Escape all single quotes in our value using sed; this is made
          #    more awkward since we're using single-quoted Nix strings...
          #  - Surround this escaped value in single quotes, hence making a
          #    fully escaped text value which won't mess up any content
          #  - Surround this single-quoted-and-escaped value in double quotes.
          #    These "cancel out" the double quotes added by makeWrapper, i.e.
          #    instead of FOO -> "FOO", we do "FOO" -> ""FOO"", and hence the
          #    value FOO (in this case, our single-quoted-escaped-value) appears
          #    OUTSIDE the double quotes, and is hence free to use single quotes

          # Pro tip to any readers: try to avoid unintended string
          # interpretation wherever you can. Instead of "quoting variables where
          # necessary", you should always quote all variables; instead of
          # embedding raw strings into generated scripts and sprinkling around
          # some quote marks, you should always escape them properly (in Bash,
          # this is done by escaping single quotes wrapping in single quotes);
          # never treat double quotes as an escaping mechanism.

           VAL="''${!ARG}"
            BS='\'
             T="'"
           ESC=$(echo "$VAL" | sed -e "s/$T/$T$BS$BS$T$T/g")

          ARGS=("''${ARGS[@]}" "--set" "''${!NAME}" "\"'$ESC'\"")
        done

        makeWrapper "$f" "$out" "''${ARGS[@]}"
      '';
};

args: withDeps (attrValues checks) (wrap args)
