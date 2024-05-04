#!/usr/bin/env bash

set -eu
[ "${DEBUG:-0}" = "1" ] && set -x


SCRIPTDIR="$(dirname "${BASH_SOURCE[0]}")"
export PATH="$SCRIPTDIR:$PATH"

if [ "$1" = "trigger_build" ] ; then
    shift 1
    circleci-manage.sh trigger_build "$@"
fi
