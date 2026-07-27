# shellcheck shell=bash
# (No shebang: this file is sourced, never executed. The directive above names
# the dialect to lint as, which cannot otherwise be inferred. Careful — any
# comment starting with the word "shellcheck" is parsed as a directive.)
#
# minixrs SDK environment. Source from a shell or script:
#   . scripts/env.sh
#
# MINIXRS_SDK is the single install prefix shared by every build script and
# every consumer (minixrs CI, cmake/minixrs.cmake, rustc bootstrap). Layout
# contract: docs/sysroot-layout.md.
#
# This file also owns the source-tree layout contract:
#
#   MINIXRS_FORKS_DIR  where the fork checkouts live. Default is the
#                      case-sensitive volume managed by forks-volume.sh —
#                      NOT a sibling of this repo, because macOS' Data
#                      volume is case-insensitive and both the LLVM and Rust
#                      trees need case sensitivity.
#   MINIXRS_SRC        the minixrs OS repo. Stays a sibling of this repo: it
#                      is not a fork and does not move onto the volume.
#
# MINIXRS_SDK keeps its ~/toolchains default deliberately — the installed SDK
# needs no case sensitivity and should stay usable when the volume is not
# mounted.

# This file is sourced, not executed, so it has to find itself: BASH_SOURCE
# under bash (every script here), $0 under zsh (the interactive shell), which
# sets $0 to the sourced file. Getting this wrong is silent — the paths below
# just come out relative to the wrong directory.
_MINIXRS_SELF="${BASH_SOURCE[0]:-$0}"
_MINIXRS_REPO_ROOT="$(cd "$(dirname "$_MINIXRS_SELF")/.." && pwd)"

export MINIXRS_SDK="${MINIXRS_SDK:-$HOME/toolchains/minixrs}"
export MINIXRS_FORKS_DIR="${MINIXRS_FORKS_DIR:-$HOME/src/minixrs-forks}"
export MINIXRS_SRC="${MINIXRS_SRC:-$(dirname "$_MINIXRS_REPO_ROOT")/minixrs}"

# Where build-musl.sh writes minixrs' generated ABI headers and where
# build-sysroot.sh looks for the abi-selftest.c they come with. A build
# artifact, not part of the SDK — it lives here only because both scripts have
# to agree on one path, and a default duplicated in two scripts drifts.
export MINIXRS_GEN_C_HEADERS_DIR="${MINIXRS_GEN_C_HEADERS_DIR:-$MINIXRS_FORKS_DIR/build/gen-c-headers}"

case ":$PATH:" in
    *":$MINIXRS_SDK/bin:"*) ;;
    *) export PATH="$MINIXRS_SDK/bin:$PATH" ;;
esac
