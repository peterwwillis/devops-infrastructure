#!/usr/bin/env sh
# test-chart-values.sh - test a single chart's template using prod deployment values
set -u
[ "${DEBUG:-0}" = "1" ] && set -x

_run_cmd () {
    chartdir="$1" yaml_file="$2"; shift 2
    chartname="$(yq e '.name' "$chartdir/Chart.yaml")"
    if [ -z "$chartname" ] ; then
        _error "could not find 'name' in '$chartdir/Chart.yaml'"
    fi
    tmpfile="$(mktemp)"
    yq e \
        '{"global": .global } * .'"$chartname" \
        "$yaml_file" \
        > "$tmpfile" \
        || _error "Problem creating yaml file"
    export HELM_TEMPLATE_OPTS_EXTRA="${HELM_TEMPLATE_OPTS_EXTRA:-} -f $tmpfile"
    make -C "$chartdir" "$@"
    ret=$?
    rm -f "$tmpfile"
    return $ret
}
_error () { echo "$0: ERROR: $*" 1>&2 ; exit 1 ; }
_usage () {
    cat <<EOUSAGE
Usage: $0 CHARTDIR PROD-VALUES-YAML-FILE MAKECMD [..]

Goes into CHARTDIR and runs Make commands, passing a new
values.yaml file crafted from a PROD-VALUES-YAML-FILE.

Because the production values.yaml files have a section for
each sub-chart, you can't use this file as-is to test a single
chart. You need a values.yaml file which contains the chart's
values at the root of the document, not in a sub-chart section.

This script does the right thing, allowing you to run whatever
Make command you want with the right values passed.
EOUSAGE
    exit 1
}

[ $# -gt 0 ] || _usage

_run_cmd "$@"
