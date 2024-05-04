#!/usr/bin/env bash
set -eu
[ "${DEBUG:-0}" = "1" ] && set -x

_cleanup () {
    if [ -n "${tmpdir:-}" ] ; then
        rm -rf "$tmpdir"
    fi
}
trap _cleanup EXIT

_make_template () {
    local src="$1" dst="$2" answers="$3" ; shift 3
    answerfn="$(basename "$(printf "%s\n" "$answers")" .yaml \
        | sed -E 's/^deployment-container-//g')"
    if [ "$FORCE" = "1" ] && [ -d "$dst/$answerfn" ] ; then
        echo "$0: Warning: destination '$dst/$answerfn' already exists - but continuing anyway!"
    elif [ -d "$dst/$answerfn" ] ; then
        echo "$0: Warning: destination '$dst/$answerfn' already exists; skipping"
        return
    fi
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir"
    # Have to copy the symlinks over or 'copier' will die when the Makefile symlink
    # cannot resolve (because it's a relative symlink)
    # also work around cp's dumbness
    src_bn="$(basename "$src")"
    cp -p -L -R "$src" "$tmpdir/"
    cp "$answers" "$tmpdir/$src_bn/copier.yaml"
    copier -l copy "$tmpdir/$src_bn" "$dst"
    rm -rf "$tmpdir"
}

_main () {
    for y in $ANSWERS_DIR/*.yaml ; do
        _make_template "$SOURCE" "$DEST" "$y"
    done
}

_err () { echo "$0: Error: $*" ; exit 1 ; }
_usage () {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
    -s DIR          Source copier template
    -d DIR          Destination to put generated copy in
    -A DIR          Directory of *.yaml files to use as answers
EOF
    exit 1
}

FORCE="${FORCE:-0}"
while getopts "s:d:A:f" arg ; do
    case "$arg" in
        s)  SOURCE="$OPTARG" ;;
        d)  DEST="$OPTARG" ;;
        A)  ANSWERS_DIR="$OPTARG" ;;
        f)  FORCE=1 ;;
        *)  _usage ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${SOURCE:-}" ] || [ -z "${DEST:-}" ] || [ -z "${ANSWERS_DIR:-}" ] ; then
    _usage
fi

_main "$@"
