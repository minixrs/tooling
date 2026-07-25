# minixrs SDK environment. Source from a shell or script:
#   . scripts/env.sh
#
# MINIXRS_SDK is the single install prefix shared by every build script and
# every consumer (minixrs CI, cmake/minixrs.cmake, rustc bootstrap). Layout
# contract: docs/sysroot-layout.md.

export MINIXRS_SDK="${MINIXRS_SDK:-$HOME/toolchains/minixrs}"

case ":$PATH:" in
    *":$MINIXRS_SDK/bin:"*) ;;
    *) export PATH="$MINIXRS_SDK/bin:$PATH" ;;
esac
