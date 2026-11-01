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
else
	case "$outfile" in
		/* | [A-Za-z]:*) ;;
		*) outfile=$PWD/$outfile ;;
	esac
fi
mkdir -p "$(dirname "$outfile")"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lye-compile.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# GNU tar can ignore index entries deleted from the working tree; bsdtar (macOS)
# has no such option, but still archives the files that exist.
tar_ignore=
if tar --ignore-failed-read -cf /dev/null -T /dev/null 2>/dev/null; then
	tar_ignore=--ignore-failed-read
fi

(
	cd "$root"
	git ls-files -z --cached --others --exclude-standard |
		tar --null $tar_ignore -cf - -T - |
		tar -xf - -C "$tmp"
) || {
	echo "compile.sh: could not snapshot the working tree" >&2
	exit 1
}

# `--ensure-mingw` is a command of its own: lde installs the toolchain and
# returns, ignoring the rest of the line, so it cannot prefix `compile`.
if [ "$ensure_mingw" = 1 ]; then
	lde --ensure-mingw
fi

(
	# lde does not treat a Windows drive path as absolute: it prepends its
	# working directory to both -C and --outfile. Work from the snapshot with
	# relative paths, then move the result to the caller's path.
	cd "$tmp"
	set -- compile -C packages/lye-lsp --outfile ../../lye-lsp
	[ -n "$target" ] && set -- "$@" --target "$target"

	lde "$@"
)

mv "$tmp/lye-lsp" "$outfile"
