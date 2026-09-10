# Development environment for Timer-Core.
#
# The two VeriSnip dependencies are pinned by revision and fetched on demand,
# so nothing has to be cloned by hand and the generator scripts cannot drift.
# Entering this shell exports Utils_DIR and OpenLibrary_DIR; the Makefile
# reads both with ?=, so it picks them up automatically.
#
# Note that Utils-Tool's own shellHook still does an unpinned
# `pip install verisnip`, so the vs_build version is not covered by this.
#
# To work against a local checkout instead of a pinned revision:
#   nix-shell --arg openLibraryDir /path/to/Open-Library
#   nix-shell --arg utilsDir /path/to/Utils-Tool
{
  pkgs ? import <nixpkgs> { },
  utilsDir ? builtins.fetchGit {
    url = "https://github.com/VeriSnip/Utils-Tool.git";
    rev = "947cd5087a0c9d4f44dd84349161daee624d6039";
  },
  openLibraryDir ? builtins.fetchGit {
    url = "https://github.com/VeriSnip/Open-Library.git";
    rev = "f46c9643799f279c201d482b457da9554f91ea6b";
  },
}:
let
  utils = toString utilsDir;
  openLibrary = toString openLibraryDir;
in
(import "${utils}/shell.nix" { inherit pkgs; }).overrideAttrs (old: {
  shellHook = old.shellHook + ''
    export Utils_DIR=${utils}
    export OpenLibrary_DIR=${openLibrary}
    # The generator scripts import each other from a read-only store path;
    # this stops Python attempting a __pycache__ write next to them.
    export PYTHONDONTWRITEBYTECODE=1
  '';
})
