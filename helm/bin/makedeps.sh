#!/usr/bin/env sh
set -eu
[ "${DEBUG:-0}" = "1" ] && set -x

_info () { echo "$(basename "$0"): Info: $*" ; }
_err () { echo "$(basename "$0"): Error: $*" 1>&2 ; }

_main () {
    opwd="$(pwd)"
    if [ -d "${HELM_CHART}/charts" ] ; then
        _info "Dir ${HELM_CHART}/charts exists; rebuilding subcharts in ${HELM_CHART}/charts "
        cd "${HELM_CHART}/charts"
        /bin/ls | xargs -P"${PARALLEL_DEPS:-10}" -n1 "$0" process_chart
    fi
    cd "$opwd"
    if [ -d "${HELM_CHART}/charts" ] || [ "${HELM_CHART}" = "." ] ; then
        _info "Dir ${HELM_CHART}/charts exists or ${HELM_CHART} is .; rebuilding chart in $opwd"
        (
            helm dependency update "${HELM_CHART}" --skip-refresh 2>&1 | grep -v -F walk.go
            helm dependency build "${HELM_CHART}" --skip-refresh 2>&1 | grep -v -F walk.go
        ) || true # Avoid error from grep when no output was found
    fi
}

_cmd_process_chart () {
    d="$1"
    if [ -d "$d" ] ; then
        _info "Making helm dep: $d"
        tmpf="$(mktemp)"
        if ! make --directory="$d" deps 1>"$tmpf" 2>&1 ; then
            _err "HELM DEPENDENCY $d FAILED; check log $tmpf"
            grep -H -E "" "$tmpf"
            exit 1
        fi
        rm -f "$tmpf"
    fi
}

if [ $# -gt 0 ] && [ "$1" = "process_chart" ] ; then
    shift
    _cmd_process_chart "$@"
else
    _main "$@"
fi
