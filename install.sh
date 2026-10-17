#!/bin/sh
# Build bosectl (release) and install it to a local bin directory.
#
# Usage:
#   ./install.sh              # installs to ~/.local/bin
#   ./install.sh /usr/local   # installs to /usr/local/bin
#   PREFIX=~/opt ./install.sh  # installs to ~/opt/bin
#
# The install prefix comes from (in order): $1, $PREFIX, then ~/.local.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${1:-${PREFIX:-$HOME/.local}}
bindir=$prefix/bin

swift build --package-path "$here" -c release --product bosectl
mkdir -p "$bindir"
cp "$here/.build/release/bosectl" "$bindir/bosectl.tmp"
chmod 755 "$bindir/bosectl.tmp"
mv -f "$bindir/bosectl.tmp" "$bindir/bosectl"

printf '\ninstalled: %s/bosectl (%s)\n' "$bindir" "$("$bindir/bosectl" --version)"
case ":$PATH:" in
    *":$bindir:"*) ;;
    *) printf 'note: %s is not on your PATH; add it, e.g.\n  export PATH="%s:$PATH"\n' "$bindir" "$bindir" ;;
esac
