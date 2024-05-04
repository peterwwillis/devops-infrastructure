#!/usr/bin/env bash
# circleci-manage.sh - Shell script to run CircleCI paramaterized jobs
# Version 2.0.0

# shellcheck disable=SC2317
set -eu
[ "${DEBUG:-0}" = "1" ] && set -x

LOOP_WAIT_TIME="${LOOP_WAIT_TIME:-5}"

CIRCLECI_VCS="${CIRCLECI_VCS:-}"
CIRCLECI_VCS_ORG="${CIRCLECI_VCS_ORG:-}"
CIRCLECI_VCS_PROJECT="${CIRCLECI_VCS_PROJECT:-}"
CIRCLE_TOKEN="${CIRCLE_TOKEN:-}"
CIRCLE_BUILD_NUM="${CIRCLE_BUILD_NUM:-}"
GIT_COMMIT_BRANCH="${GIT_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD || true)}"

CIRCLECI_MANAGE_SCRIPT="${CIRCLECI_MANAGE_SCRIPT:-circleci-ctl.py}"

#############################################################################

VERBOSE=0

_verbose () { if [ $VERBOSE -eq 1 ] ; then _info "$@" ; fi ; }
_info () { printf "%s: %s: %s: %s\n" "$(basename "$0")" "$(date -Iseconds)" "Info" "$@" 1>&2 ; }
_err () { printf "%s: %s: %s: %s\n" "$(basename "$0")" "$(date -Iseconds)" "Error" "$@" 1>&2 ; }
_die () { _err "$@" ; exit 1 ; }

_get_projects_json () {
    "$CIRCLECI_MANAGE_SCRIPT" get_project_jobs \
        --vcs="$CIRCLECI_VCS" \
        --org="$CIRCLECI_VCS_ORG" \
        --projects="$CIRCLECI_VCS_PROJECT" \
        --filter=running \
        --maxpages=1 \
        | jq -e -r '[ .[].item ]'
}

_update_projects_json_with_workflows () {
    local jsonfile="$1"; shift
    local tmpf

    while read -r workflow_id ; do
        _info "Retrieving workflow id '$workflow_id'"

        # Get created_at time from workflow
        tmpf="$(mktemp -t "workflow.$RANDOM.json")"
        "$CIRCLECI_MANAGE_SCRIPT" get_workflow \
            --workflow="$workflow_id" \
            --maxpages=1 \
            | jq -e -r '.[].item' > "$tmpf"
        workflow_created_at="$(jq -e -r '.created_at' "$tmpf")"
        rm -f "$tmpf"

        # Update project.json with new created_at entry
        tmpf="$(mktemp -t "tmp.$RANDOM.json")"
        cp -f "$jsonfile" "$tmpf"
        jq -e -r \
            --arg created_at "$workflow_created_at" \
            --arg workflow "$workflow_id" \
            '( .[] | select(.workflows.workflow_id == $workflow) | .workflows) |= . + {created_at:$created_at}' \
            "$jsonfile" > "$tmpf"
        mv -f "$tmpf" "$jsonfile"
    done < <(jq -e -r '.[] | .workflows.workflow_id //empty' "$jsonfile" | sort | uniq)
}

_cmd_wait_for_job_end () {
    # Query for jobs running with a specific $name. As long as that
    # name matches a running job, infinitely loop. Once no more jobs
    # are found, return success.
    local job_name="$1" cur_build_num="${CIRCLE_BUILD_NUM:-${2:-}}"
    local jsonfile current_creation_time='' oldest_build=''
    local oldest_build_num='' oldest_creation_time=''

    while true ; do

        jsonfile="$(mktemp -t "projects.$RANDOM.json")"
        _get_projects_json > "$jsonfile"
        if ! jq -e -r '.[0]' "$jsonfile" >/dev/null ; then
            _verbose "No running workflows found"
            rm -f "$jsonfile"
            return 0
        fi

        _update_projects_json_with_workflows "$jsonfile"

        oldest_build="$( jq -e -r --arg name "$job_name" \
                '.[] | select(.workflows.job_name == $name)' "$jsonfile" \
                | jq -e -r -s 'sort_by(.workflows.created_at) | .[0]' )"
        oldest_build_num="$( printf "%s\n" "$oldest_build" | jq -e -r '.build_num' )"
        oldest_creation_time="$( printf "%s\n" "$oldest_build" | jq -e -r '.workflows.created_at' )"

        if [ -n "$cur_build_num" ] ; then
            current_creation_time="$( jq -e -r --arg num "$cur_build_num" \
                '.[] | select(.build_num == ($num|tonumber)).workflows.created_at' \
                "$jsonfile" )"

            _verbose "current_creation_time: $current_creation_time"
            _verbose "oldest_build_num: $oldest_build_num"
            _verbose "oldest_creation_time: $oldest_creation_time"

            if [ "$oldest_build_num" = "$cur_build_num" ] ; then
                _verbose "oldest build is the current build, so begin building"
                rm -f "$jsonfile"
                return 0
            elif [[ "$oldest_creation_time" > "$current_creation_time" ]] || \
                 [[ "$oldest_creation_time" = "$current_creation_time" ]] ; then
                _verbose "oldest build that we found is after our current build time, so begin building"
                rm -f "$jsonfile"
                return 0
            fi
        fi

        rm -f "$jsonfile"
        sleep "$LOOP_WAIT_TIME"

    done
}

# Usage: _compose_json BRANCH [ '"foo"="bar"' '"baz"=false' .. ]
_compose_json () {
    local c=0 branch="$1"
    local -a data_tmpl args=("$@")
    data_tmpl+=( '{' '  "branch": "'"$branch"'"' )

    if [ ${#args[@]} -gt 0 ] ; then
        data_tmpl+=( '  , "parameters": {' )
        while [ $c -le ${#args[@]} ] ; do
            if [ $c -ne ${#args[@]} ] ; then
                data_tmpl+=( "    ${args[$c]} ," )
            else
                data_tmpl+=( "    ${args[$c]}" )
            fi
        done
    fi

    data_tmpl+=( '}' )
    printf "%s\n" "${data_tmpl[@]}"
}

# Usage: _circleci_trigger_pipeline VCS ORG PROJECT BRANCH [ARGS..]
_circleci_trigger_pipeline () {
    local vcs="$1" org="$2" project="$3" branch="$4"
    shift 4
    local circleci_pipeline_url="https://circleci.com/api/v2/project/$vcs/$org/$project/pipeline"
    curl --silent --fail-with-body --location \
        --request POST "$circleci_pipeline_url" \
        --header 'Content-Type: application/json' \
        --header "Circle-Token: $CIRCLE_TOKEN" \
        --data-raw "$(_compose_json "$branch" "$@")"
    # returns:
    # {
    #   "number" : 1234,
    #   "state" : "setup-pending",
    #   "id" : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    #   "created_at" : "2020-01-10T15:33:12.123Z"
    # }
}

_circleci_wait_for_pipeline_status () {
    local pipeline_id="$1" wanted_status="$2"
    local url="https://circleci.com/api/v2/pipeline/$pipeline_id/workflow"
    local curstatus=""
    _info "Waiting for all of CircleCI pipeline $pipeline_id workflows to reach status '$wanted_status' ..."
    while true ; do
        set +e
        result="$(curl --silent --fail-with-body --location --header "Circle-Token: ${CIRCLE_TOKEN}" "$url")"
        # shellcheck disable=SC2181
        if [ $? -ne 0 ] || [ -z "$result" ] ; then
            _info "Got an error or unexpected value while trying to retrieve CircleCI pipeline status"
            exit 1
        fi

        result_statuses="$(printf "%s\n" "$result" | jq -r '.items[] | .id+"="+.status')"
        result_count="$(printf "%s\n" "$result_statuses" | wc -l | tr -d '[:space:]')"
        result_wanted="$(printf "%s\n" "$result_statuses" | grep -c -F "=$wanted_status")"
        result_failed="$(printf "%s\n" "$result_statuses" | grep -c -F "=failed")"
        result_canceled="$(printf "%s\n" "$result_statuses" | grep -c -F "=canceled")"

        if [ ! "$result_statuses" = "$curstatus" ] ; then
            _info "Workflow status:"
            for arg in $result_statuses ; do _info "  $arg" ; done
            _info ""
            curstatus="$result_statuses"
        fi

        if [[ $result_wanted -eq $result_count ]] ; then
            _info "All statuses accounted for"
            return 0
        elif [[ $result_failed -eq 1 ]] ; then
            _info "Found a failed status; exiting early"
            return 1
        elif [[ $result_canceled -eq 1 ]] ; then
            _info "Workflow was canceled; exiting early"
            return 1
        fi

        sleep 10
        set -e
    done
}

# Usage: _cmd_trigger_build BRANCH WAIT VCS ORG PROJECT BRANCH [ARGS ..]
_cmd_trigger_build () {
    local git_branch="$1" wait_for_success="$2" ; shift 2
    local vcs="$1" org="$2" project="$3" ; shift 3
    local ret trigger_result pipeline_id

    [ -n "${git_branch:-}" ] || _usage

    set +e  # avoid exit on error of following command; gather its return status instead
    trigger_result="$( _circleci_trigger_pipeline "$vcs" "$org" "$project" "$branch" "$@" )"
    ret=$?
    if [ $ret -eq 0 ] && [ -n "$trigger_result" ] ; then
        printf "%s\n" "$trigger_result"
    else
        _err "Circleci trigger returned an error or unexpected value (curl returned: $ret)"
        _err "Curl result: '$trigger_result'"
        exit $ret
    fi
    set -e

    pipeline_id="$(printf "%s\n" "$trigger_result" | jq -r .id)"

    if [[ $wait_for_success -eq 1 ]] ; then
        _circleci_wait_for_pipeline_status "$pipeline_id" "success"
    fi
}


_usage () {
    cat <<EOUSAGE
Usage: $0 [OPTS] COMMAND [..]

Commands:

    wait_for_job_end NAME [BUILD]       Waits for job NAME to end running. If BUILD is passed,
                                        assumes that is the build number of the job we want to
                                        run after all the same-named jobs with earlier creation
                                        dates have run. Defaults to CIRCLE_BUILD_NUM. If neither
                                        BUILD nor CIRCLE_BUILD_NUM are found, just waits until
                                        all jobs named NAME are done.

    trigger_build [ARGS ..]             Trigger a build, passing in optional ARGS parameters.
                                        Each argument is passed as a literal JSON string.
                                        You can pass quoted strings, or true/false/null,
                                        but make sure you put quotes around strings. Do
                                        not add a ',' at the end of each argument, one
                                        will be added as necessary.


Options:
    -h                  This help screen
    -b BRANCH           Git commit branch to send to job.  Defaults to GIT_COMMIT_BRANCH (if set)
                        or the current git branch reported from 'git'.
    -v VCS              Version control name ('bitbucket', 'github')
    -o ORG              VCS Organization name
    -p                  VCS Project name (repo name)
    -w                  Wait for the pipeline to succeed
EOUSAGE
    exit 1
}

wait_for_success=0
while getopts "hwb:v:o:p:" args ; do
      case "$args" in
          h)    _usage ;;
          w)    wait_for_success=1 ;;
          b)    GIT_COMMIT_BRANCH="$OPTARG" ;;
          v)    CIRCLECI_VCS="$OPTARG" ;;
          o)    CIRCLECI_VCS_ORG="$OPTARG" ;;
          p)    CIRCLECI_VCS_PROJECT="$OPTARG" ;;
          *)    _usage "Invalid option '$args'" ;;
      esac
done
shift $((OPTIND-1))

if [ $# -lt 1 ] ; then
    _usage
fi

cmd="$1"; shift
case "$cmd" in
    wait_for_job_end)       _cmd_wait_for_job_end "$@" ;;
    trigger_build)          _cmd_trigger_build \
                                "$GIT_COMMIT_BRANCH" \
                                "$wait_for_success" \
                                "$CIRCLECI_VCS" "$CIRCLECI_VCS_ORG" "$CIRCLECI_VCS_PROJECT" \
                                "$@" ;;
esac
exit $?
