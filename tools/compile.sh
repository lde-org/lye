#!/bin/sh
# Compile lye-lsp from a snapshot of this checkout, not from the checkout itself.
#
# `lde compile -C packages/lye-lsp` walks the package's source, and a checkout that
# has run the test suite has generated fixtures under packages/lye-lsp/target/ that
# are not valid sources. This copies the tracked working tree (local edits and new
# files included, ignored build output excluded) to a temporary directory and
# compiles there, leaving the caller's target/ untouched.

set -eu

usage() {
	cat <<'EOF'
usage: tools/compile.sh [--target <target>] [--outfile <path>] [--ensure-mingw]

  --target <target>   cross-compile for an lde release target
  --outfile <path>    where to write the binary (default: packages/lye-lsp/lye-lsp)
  --ensure-mingw      ask lde to install its Windows toolchain too

Run from anywhere in the repository. Local edits are compiled, but ignored files
such as target/ and .lye/ are not.
EOF
}

target=""
outfile=""
ensure_mingw=0

while [ $# -gt 0 ]; do
	case "$1" in
		--target)
			[ $# -ge 2 ] || { echo "compile.sh: --target needs a value" >&2; exit 2; }
			target=$2
			shift 2
			;;
		--outfile)
			[ $# -ge 2 ] || { echo "compile.sh: --outfile needs a value" >&2; exit 2; }
			outfile=$2
			shift 2
			;;
		--ensure-mingw)
			ensure_mingw=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "compile.sh: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

command -v lde >/dev/null 2>&1 || {
	echo "compile.sh: lde is not on PATH (https://lde.sh/docs/general/getting-started/installation)" >&2
	exit 1
}
command -v git >/dev/null 2>&1 || {
	echo "compile.sh: git is not on PATH" >&2
	exit 1
}

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "compile.sh: not inside a git checkout" >&2
	exit 1
}

if [ -z "$outfile" ]; then
	outfile=$root/packages/lye-lsp/lye-lsp
elif [ "${outfile#/}" = "$outfile" ]; then
	outfile=$PWD/$outfile
fi
mkdir -p "$(dirname "$outfile")"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lye-compile.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

(
	cd "$root"
	git ls-files -z --cached --others --exclude-standard |
		tar --null --ignore-failed-read -cf - -T - |
		tar -xf - -C "$tmp"
) || {
	echo "compile.sh: could not snapshot the working tree" >&2
	exit 1
}

set -- compile -C "$tmp/packages/lye-lsp" --outfile "$outfile"
[ -n "$target" ] && set -- "$@" --target "$target"
[ "$ensure_mingw" = 1 ] && set -- --ensure-mingw "$@"

lde "$@"
