#!/usr/bin/env bash
# shellcheck disable=SC2155,SC2181
set -eu
[ "${DEBUG:-0}" = "1" ] && set -x

GCLOUD_IMAGE_REPO_MATCH="${GCLOUD_IMAGE_REPO_MATCH:-gcr.io/REPO_NAME/}"
# If GCLOUD_IMAGE_TAG_MATCH is set, then the code will verify that the original
# tag matches this, or skip with a warning. Safe to leave this unset.
GCLOUD_IMAGE_TAG_MATCH="${GCLOUD_IMAGE_TAG_MATCH:-}"
CHART_VALUES_REPO_KEY="${CHART_VALUES_REPO_KEY:-.image.repository}"
CHART_VALUES_TAG_KEY="${CHART_VALUES_TAG_KEY:-.image.tag}"
export GCLOUD_IMAGE_REPO_MATCH GCLOUD_IMAGE_TAG_MATCH
export CHART_VALUES_REPO_KEY CHART_VALUES_TAG_KEY
export SET_TAG_DIGEST="${SET_TAG_DIGEST:-1}"

SUBCHART="${SUBCHART:-0}"

ROOTDIR="${ROOTDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)}"
TMPDIR="${TMPDIR:-/tmp}"

_die () { echo "$(basename "$0"): Error: $*" 1>&2 ; exit 1 ; }
_info () { [ "${_quiet:-0}" = "1" ] || echo "$(basename "$0"): Info: $*" 1>&2 ; }
_tmpfile () { local f="$(printf "%s\n" "$TMPDIR/values-$(date +%s)-$RANDOM.yaml")"; touch "$f"; echo "$f"; }
_usage () {
    cat <<EOUSAGE
Usage: $0 [OPTIONS] COMMAND [ARGS ..]

This script manages the Helm values files used for deployments.

The primary purpose is to identify, query, and pin the versions of containers used
by Helm charts, so those versions can be put into a new yaml file and passed to
the chart at install time.

Commands:

  pin_version containers CHARTDIR [..]

   - Pins the SHA hash of container images based on their tag.
     Looks in a CHARTDIR Helm chart for a values.yaml file.
     Looks for key \$CHART_VALUES_REPO_KEY and \$CHART_VALUES_TAG_KEY (options -R and -T options)
       for the name and tag of the container repo for this chart.
     Queries the current versions of Google Cloud Container Registry containers that match
       repository \$GCLOUD_IMAGE_REPO_MATCH and tag \$GCLOUD_IMAGE_TAG_MATCH (options -r and -t).
     Does the same for any charts found in CHARTDIR/charts/*/values.yaml files.
   - If the -f option's value is "-", writes result to standard output.

  pin_version digest

   - Reads the file passed by -f option, and pins the digest of each tag it finds.
     (The file must be the same format as comes out of 'pin_version containers' command)

  pin_version chart CHARTDIR HELM_RELEASE [VERSION K8S_NAMESPACE]

   - Pins the Helm release version into the YAML file under 'helm-chart-release'.
     If VERSION is "current" or not specified, retrieves the currently-deployed Helm release
       and pins that.

  check_values CHARTDIR

   - Checks that a chart's subchart values exist properly in the parent chart's configuration.

Options:
    -D              Disables the lookup of the digest of a container based on its tag name.
    -r REPO         The image repo to match on [$GCLOUD_IMAGE_REPO_MATCH]. This can be
                    a basic regular expression.
    -t TAG          The image tag to match on [$GCLOUD_IMAGE_TAG_MATCH]. This can be
                    a basic regular expression.
    -f FILE         The YAML file to update versions in.
    -R KEY          The YAML key to look for in values.yaml file, to identify the container
                    repository for that chart. [$CHART_VALUES_REPO_KEY]
    -T TAG          The YAML key to look for in values.yaml file, to identify the container
                    tag for that chart. [$CHART_VALUES_TAG_KEY]

Examples:

  To output only the default values of a Helm chart's GCP containers to stdout:

    $ ./helm/bin/manage-values.sh -D -f - pin_version containers helm/HELM_CHART/

  To update the aforementioned default values with pinned tag digests:

    $ ./helm/bin/manage-values.sh -f pinned-values.yaml pin_version digest

  To update the Helm chart pinned version:

    $ ./helm/bin/manage-values.sh -f pinned-values.yaml pin_version chart helm/HELM_CHART/ HELM_CHART

EOUSAGE
    exit 1
}

# Usage: _parallelize COMMAND ARG [..]
# 
# Run '$0 COMMAND ARG', for every ARG, in parallel. We use this weird hack
# to parallelize the gcloud command, and because xargs is a little broken
# on MacOS.
PARALLEL_LIMIT="${PARALLEL_LIMIT:-10}"
_parallelize () {
    local cmd="$1"; shift
    for d in "$@" ; do
        printf "%s\n" "$d"
    done \
        | xargs -P"$PARALLEL_LIMIT" -n1 "$0" "$cmd"
}

# Usage: _cmd_pin_version_containers CHARTDIR
# 
# Pins the versions of container image/tag combos found in the
# values.yaml of a CHARTDIR.
# Output is the path to a temp file with the new yaml values.
# 
# Looks for this in the values.yaml:
#
#   deployment:
#     image:
#       tag: NAME
#       repository: URL
# 
# The actual values to match on are defined in CHART_VALUES_REPO_KEY, CHART_VALUES_TAG_KEY,
# GCLOUD_IMAGE_REPO_MATCH, GCLOUD_IMAGE_TAG_MATCH and can be overriden at run time.
# The repo and tag are looked up in gcloud, the image's SHA hash is retrieved, and is set
# in the yaml output.
# 
_cmd_pin_version_containers () {
    local chartdir="$1" chartname="$(basename "$1")"
    local chartprefix=""
    if [ "${SUBCHART:-0}" = "1" ] ; then
        chartprefix=".$chartname"
    fi

    if [ ! -e "$chartdir/values.yaml" ] ; then
        _info "No file '$chartdir/values.yaml' found; skipping chart" 1>&2
        return 0
    fi

    _gen_chart_container_list \
        "$chartname" \
        "$chartdir/values.yaml" \
        "$chartprefix" \
        "$CHART_VALUES_REPO_KEY" \
        "$CHART_VALUES_TAG_KEY" \
        "$SET_TAG_DIGEST"
}

_cmd_pin_version_digest () {
    local chartname="$1"; shift 1
    _gen_chart_container_list \
        "$chartname" \
        "$YAML_FILE" \
        "" \
        ".$chartname$CHART_VALUES_REPO_KEY" \
        ".$chartname$CHART_VALUES_TAG_KEY" \
        "$SET_TAG_DIGEST"
}

# Usage: _gen_chart_container_list NAME VALUESFILE PREFIX REPOKEY TAGKEY [SETTAGDIGEST]
# 
# If SETTAGDIGEST is '1', looks up the digest of the tag and pins that.
_gen_chart_container_list () {
    local chartname="$1" chart_values_file="$2"
    local chartprefix="$3" repo_key="$4" tag_key="$5"
    local set_tag_digest="${6:-0}"

    set +e
    # The k8 resource prefix is the k8 type ie deployment, job, cronjob etc.
    # We get this by grabbing the top-level keys for the service in the values file, and since
    # there's only one, we grab the first in the list
    # alert-manager
    #   deployment:
    #     image:
    #       repository: gcr.io/REPO_NAME/alert-manager
    #       tag: staging@sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    # populate-sql-db-hook-pre-install:
    #   job:
    #     image:
    #       repository: gcr.io/REPO_NAME/populate-sql-db
    #       tag: staging@sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    # This will result in deployment for alert-manager and job for populate-sql-db-hook-pre-install
    local k8_resource_prefix=".$(yq '. | keys | .0' "$chart_values_file" 2>/dev/null )"
    if [ $? -ne 0 ] || [ "$k8_resource_prefix" = "." ] || [ "$k8_resource_prefix" = ".null" ] ; then
        _info "Chart $chartname: Key '$k8_resource_prefix' not found in '$chart_values_file'; skipping"
        return 0
    fi

    # Look for the repo
    local repo="$( yq -e -r "$k8_resource_prefix$repo_key" "$chart_values_file" 2>/dev/null )"
    if [ $? -ne 0 ] || [ -z "$repo" ] || [ "$repo" = "null" ] ; then
        _info "Chart $chartname: Key '$k8_resource_prefix$repo_key' not found in '$chart_values_file'; skipping"
        return 0
    fi
    # Look for the tag
    local tag="$( yq -e -r "$k8_resource_prefix$tag_key" "$chart_values_file" 2>/dev/null )"
    if [ $? -ne 0 ] || [ -z "$tag" ] || [ "$tag" = "null" ] ; then
        _info "Chart $chartname: Key '$k8_resource_prefix$tag_key' not found in '$chart_values_file'; skipping"
        return 0
    fi
    set -e

    # Check the repo matches GCLOUD_IMAGE_REPO_MATCH.
    # This way we can skip charts referencing a repo we don't care about.
    if [ "$(expr "$repo" : "$GCLOUD_IMAGE_REPO_MATCH")" = "0" ] ; then
        _info "Chart $chartname: Repo '$repo' did not match '$GCLOUD_IMAGE_REPO_MATCH'; skipping"
        return 0
    fi
    # Check the tag matches, only if GCLOUD_IMAGE_TAG_MATCH was set.
    # This way we can skip charts referencing a repo we don't care about,
    # while allowing a user to override the tag if they want.
    if [ -n "${GCLOUD_IMAGE_TAG_MATCH:-}" ] ; then
        if [ "$(expr "$tag" : "$GCLOUD_IMAGE_TAG_MATCH")" = "0" ] ; then
            _info "Chart $chartname: Tag '$tag' did not match '$GCLOUD_IMAGE_TAG_MATCH'; skipping"
            return 0
        fi
    fi

    tag_value="$tag"
    if [ "$set_tag_digest" -eq 1 ] ; then

        # To list repo names, run:
        #   gcloud container images list --repository=gcr.io/REPO --format "value(name)"
        local digest="$( gcloud container images list-tags "$repo" --filter "tags ~ ^${tag}$" --format "get(digest)" )"
        if [ -z "$digest" ] ; then
            _info "Chart $chartname: No digest found for $repo:$GCLOUD_IMAGE_TAG_MATCH ; skipping"
            return 0
        fi

        tag_value="$tag@$digest"
    fi

    local tmpfile="$(_tmpfile)"
    yq -i "$chartprefix$k8_resource_prefix$repo_key = \"$repo\"" "$tmpfile"
    yq -i "$chartprefix$k8_resource_prefix$tag_key = \"$tag_value\"" "$tmpfile"
    echo "$tmpfile"
}

# Usage: _cmd_pin_version_chart CHARTDIR HELMRELEASE VERSION K8S_NAMESPACE
# 
# Queries and pins the Helm release version.
# Output is the path to a temp file with the new yaml output.
_cmd_pin_version_chart () {
    local chartdir="$1" chartname="$(basename "$1")"
    local helm_release="${2:-}" version="${3:-}" k8s_ns="${4:-}"

    # Default to currently selected namespace if none specified
    declare -a kubectl_opts=(kubectl config view --minify -o jsonpath='{..namespace}')
    [ -n "$k8s_ns" ] || k8s_ns="$( "${kubectl_opts[@]}" )"
    [ -n "$k8s_ns" ] || _die "Namespace could not be detected; please pass namespace to command"

    tmpfile="$(_tmpfile)"

    if [ -z "$version" ] || [ "$version" = "current" ] ; then

        # Retrieve the currently deployed Helm release's info and pin it in the yaml file.
        # Only retrieves/pins the "chart" entry, which includes the chart version.
        helm_chart_ver="$(helm list \
            --namespace "$k8s_ns" \
            -l "name=$helm_release,owner=helm,status=deployed" \
            -o json \
          | jq -e -r -M '.[].chart')"
        [ -n "$helm_chart_ver" ] || _die "No helm chart release/version found from 'helm list' (ns: $k8s_ns, release: $helm_release)"

        new_json="$(jq -n -e -r -M --arg release "$helm_release" --arg chart "$helm_chart_ver" \
            '{"helm-chart-release": { ($release) : { "chart": ($chart) } }}')"
        [ -n "$new_json" ] || _die "Could not craft json message"

        printf "%s\n" "$new_json" | yq eval-all \
            --exit-status --output-format=yaml --prettyPrint --no-doc --no-colors \
          > "$tmpfile"

    elif [ -n "$version" ] && [ -n "$helm_release" ] && [ -n "$k8s_ns" ] ; then

        # This mimics how our charts' name/version are specified
        yq --inplace ".helm-chart-release.$helm_release.chart = \"$helm_release-$version\"" "$tmpfile"

    else
        _die "Please pass the following arguments: HELM_RELEASE VERSION K8S_NAMESPACE"
    fi

    if [ ! -s "$tmpfile" ] ; then
        _die "Error pinning chart: no values found"
    fi

    echo "$tmpfile"
}

# Usage: _cmd_pin_version SUBCOMMAND CHARTDIR [CHARTPREFIX]
# 
# Runs either '_cmd_pin_version_containers' or '_cmd_pin_version_chart'.
# 
# Output is a YAML file that's a merging of all the outputs of the command(s) in question.
# 
# CHARTPREFIX is added before the chart name when adding to the values.yaml file,
# so you can keep sub-charts in a different yaml path in the file.
_cmd_pin_version () {
    local subcommand="$1" ; shift 1
    local tmpfile="" result="" version=""
    declare -a tmp_files=()

    if [ -z "${YAML_FILE:-}" ] ; then
        _die "Please pass -f option or pass YAML_FILE= environment variable"
    fi

    if [ "$subcommand" = "containers" ] ; then

        local chartdir="${1:-}"
        if [ -z "${chartdir:-}" ] ; then
            _die "Please pass a chart directory to the 'pin_version $subcommand' command"
        fi

        result="$(_cmd_pin_version_containers "$chartdir")"
        [ -z "$result" ] || tmp_files+=( "$result" )

        # Do sub-charts
        if [ -d "$chartdir/charts" ] ; then
            # shellcheck disable=SC2046
            while read -r LINE ; do
                [ -z "$LINE" ] || tmp_files+=("$LINE")
            done < <(SUBCHART=1 _parallelize pin_version_containers $(ls -d "$chartdir"/charts/*/) )
        fi

    elif [ "$subcommand" = "digest" ] ; then

        # shellcheck disable=SC2046
        while read -r LINE ; do
            [ -z "$LINE" ] || tmp_files+=("$LINE")
        done < <(_parallelize pin_version_digest $(yq 'keys | .[]' "$YAML_FILE") )

    elif [ "$subcommand" = "chart" ] ; then

        if [ -z "${1:-}" ] ; then
            _die "Please pass a chart directory to the 'pin_version $subcommand' command"
        fi
        result="$(_cmd_pin_version_chart "$@")"
        [ -z "$result" ] || tmp_files+=( "$result" )

    fi

    tmpfile="$(_tmpfile)"
    if [ ! "$YAML_FILE" = "-" ] && [ -e "$YAML_FILE" ] ; then
        cp -f "$YAML_FILE" "$tmpfile"
    fi

    # shellcheck disable=SC2016
    # Merge all tmp_files[@] yaml files into tmpfile yaml file.
    yq eval-all -i '. as $item ireduce ({}; . * $item )' "$tmpfile" "${tmp_files[@]}"
    yq -i 'sort_keys(..)' "$tmpfile"  # Make diffing easier later
    rm -f "${tmp_files[@]}"

    if [ ! -s "$tmpfile" ] ; then
        _die "Generated values yaml file '$tmpfile' was empty!"
    fi

    if [ ! "$YAML_FILE" = "-" ] ; then
        # Back up the yaml file before we replace it, for diffing later.
        dn="$(dirname "$YAML_FILE")" bn="$(basename "$YAML_FILE")"
        cp -f "$YAML_FILE" "${dn:-.}/prior-$bn"
        mv -f "$tmpfile" "$YAML_FILE"

    elif [ "$YAML_FILE" = "-" ] ; then
        cat "$tmpfile"
        rm -f "$tmpfile"
    fi
}

_cmd_check_values () {
    local chartdir="$1" ; shift 1
    if [ ! -d "$chartdir" ] ; then
        _info "No such chart directory '$chartdir'; skipping..."
        return 0
    fi
    if [ ! -d "$chartdir/charts" ] ; then
        _info "No subcharts for chart dir '$chartdir'; skipping..."
        return 0
    fi
    # shellcheck disable=SC2046
    HELM_CHART="$chartdir" _parallelize check_values_subchart $(ls -d "$chartdir"/charts/*/)
}

_cmd_check_values_subchart () {
    local chartdir="$HELM_CHART" subchartdir="$1" ; shift 1
    bn="$(basename "$subchartdir")"
    _info "Checking subchart values for chart '$chartdir', subchart '$bn' ..."
    if ! yq e --no-colors --exit-status \
        ".dependencies[] | select(.name == \"$bn\")" \
        "$chartdir/Chart.yaml" >/dev/null
    then
        _die "Error: subchart '$bn' not found in '$chartdir/Chart.yaml' dependencies"
    fi
    if ! yq e --no-colors --exit-status  ".$bn"  "$chartdir/values.yaml" >/dev/null
    then
        _die echo "Error: subchart '$bn' not found in '$chartdir/values.yaml'"
    fi
}


#####################################################################

[ $# -gt 0 ] || _usage

while getopts "hr:t:f:R:T:D" arg ; do
    case "$arg" in
        r)  export GCLOUD_IMAGE_REPO_MATCH="$OPTARG" ;;
        t)  export GCLOUD_IMAGE_TAG_MATCH="$OPTARG" ;;
        f)  export YAML_FILE="$OPTARG" ;;
        R)  export CHART_VALUES_REPO_KEY="$OPTARG" ;;
        T)  export CHART_VALUES_TAG_KEY="$OPTARG" ;;
        D)  export SET_TAG_DIGEST="0" ;;
        h)  _usage ;;
        *)  _die "Unknown argument '$arg'" ;;
    esac
done ; shift $((OPTIND-1)) ; OPTIND=$((OPTIND-1))

[ $# -gt 0 ] || _usage


cmd="$1"; shift
_cmd_"$cmd" "$@"
