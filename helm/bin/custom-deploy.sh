#!/usr/bin/env bash
set -eu
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPTDIR="$(dirname "${BASH_SOURCE[0]}")"

_info () { echo "$0: Info: $*" ; }
_err () { echo "$0: Warning: $*" 1>&2 ; }
_die () { echo "$0: Error: $*" 1>&2 ; exit 1 ; }

# Confirm the resulting file is a valid YAML file
_verify_yaml () {
    local file="$1"
    if ! yq eval-all -e "$file" >/dev/null ; then
        printf "%s\n%s\n" "ERROR: 'envsubst' result is invalid:" "$(cat "$file")"
        rm -f "$file"
        exit 1
    fi
}
_load_tags_file () {
    if [ -z "${TAGS_FILE:-}" ] ; then
        # Default tags.sh file: 'helm/tags.sh.default'
        TAGS_FILE="$SCRIPTDIR/../tags.sh.default"
    fi
    [ -n "${TAGS_FILE:-}" ] || _die "You must pass -t option or TAGS_FILE environment variable"
    if [ ! -e "$TAGS_FILE" ] ; then
        _die "No tags.sh file '$TAGS_FILE' found"
    fi
    # Load the tags.sh values. All variables set in the script are automatically exported.
    set -a
    # shellcheck disable=SC1090
    . "$TAGS_FILE"
    set +a
}
_load_k8s_ns () {
    [ -n "${K8S_NS:-}" ] ||  K8S_NS="$(_cmd_k8s_ns)"
    [ -n "${K8S_NS:-}" ] || \
        _die "Please pass -N option or K8S_NS"
}

# Use $deployment_identifier from tags.sh as the Kubernetes namespace
_cmd_k8s_ns () {
    k8s_ns="$(_load_tags_file ; echo "$deployment_identifier")"
    printf "%s\n" "$k8s_ns"
}

_cmd_get_values () {
    local keyname="${1:-}"; shift 1

    [ -n "$keyname" ] || _die "Please pass NAME to command 'get_values'"
    [ -n "${HELM_RELEASE:-}" ] || _die "Please pass -R option or HELM_RELEASE"

    _load_k8s_ns

    kubectl -n "${K8S_NS}" get secret "$CUSTOM_HELM_SECRET_KEY" \
        --template="{{index .data \"$keyname\" | base64decode}}"
}

# Take a $CUSTOM_HELM_TPL file (if it exists) and run it through 'envsubst',
# then create a K8s secret with the value of the result from envsubst,
# and apply it to the K8s cluster.
_cmd_upload () {

    [ -n "${HELM_CHART:-}" ] ||   _die "Please pass -C option or HELM_CHART"
    [ -n "${HELM_RELEASE:-}" ] || _die "Please pass -R option or HELM_RELEASE"

    declare -a vals_files=()
    for name in "$@" ; do

        CUSTOM_HELM_TPL="$HELM_CHART/custom-deploy.$CUSTOM_HELM_NAME.$name.tpl"
        if [ ! -e "$CUSTOM_HELM_TPL" ] ; then
            _err "Custom deploy template ('$CUSTOM_HELM_TPL') not found; skipping" 1>&2
            continue
        fi

        _load_tags_file

        # Look for any variables in the template that don't appear in the tags.sh.
        # This is a little primitive, and can be improved if needed.
        _info "Checking Helm custom template '$CUSTOM_HELM_TPL' ..."

        # shellcheck disable=SC2016
        grep -F '${' < "$CUSTOM_HELM_TPL" \
            | grep -v -E '^[[:space:]]*#' \
            | sed -E 's/.*\${([a-zA-Z0-9_-]+)}.*/\1/g' \
            | sort -u \
            | while read -r LINE ; do
                grep -q -F "$LINE" "$TAGS_FILE" \
                    || _err "Not found template variable '$LINE' in tags script"
            done

        # Replace variables in template with env vars from tags.sh
        customvals="$(mktemp)"
        envsubst < "$CUSTOM_HELM_TPL" >"$customvals"
        _verify_yaml "$customvals"
        vals_files+=("$name" "$customvals")

        echo ""
        echo "################################################################"
        echo "# Envsubst-generated $CUSTOM_HELM_TPL"
        cat "$customvals"
        echo "################################################################"
        echo ""
    done

    # End if no files generated (might not be a template in that chart)
    [ ${#vals_files[@]} -gt 0 ] || return 0

    customkcfg="$( _create_k8s_secret_file "${vals_files[@]}" )"
    if [ "$_dry_run" = "1" ] ; then
        # shellcheck disable=SC2016
        sed -E "s/^/$CUSTOM_HELM_SECRET_KEY: /g" "$customkcfg"
    else
        _create_k8s_secret "$customkcfg"
        echo ""
        echo "Your configuration is now available: kubectl -n ${K8S_NS} get secret/${CUSTOM_HELM_SECRET_KEY}"
        echo ""
    fi

    # Clean up tmp files
    c=1
    while [ $c -lt ${#vals_files[@]} ] ; do
        rm -f "${vals_files[$c]}"
        c=$((c+2))
    done
}

_cmd_edit () {
    local editor="${KUBE_EDITOR:-}"
    editor="${editor:-${EDITOR:-}}"
    editor="${editor:-open -t -n -W}"

    [ -n "${HELM_RELEASE:-}" ] || _die "Please pass -R option or HELM_RELEASE"

    declare -a vals_files=()
    for name in "$@" ; do
        local customvals="$(mktemp)"
        _cmd_get_values "$name" > "$customvals"
        vals_files+=("$name" "$customvals")
        $editor "$customvals" &
    done
    wait

    customkcfg="$(_create_k8s_secret_file "${vals_files[@]}")"
    _create_k8s_secret "$customkcfg"
}

# Usage: _create_k8s_secret_file FILENAME FILEPATH [FILENAME FILEPATH ..]
# Creates a K8s secret, encoding a set of files and their names in the
# secret .data section.
_create_k8s_secret_file () {
    _load_k8s_ns
    declare -a ckcfg_args=("--save-config" "--dry-run=client" "-o" "yaml")
    while [ $# -gt 0 ] ; do
        filename="$1" filepath="$2" ; shift 2
        ckcfg_args+=("--from-file=$filename=$filepath")
    done

    # Create the manifest for the Kubernetes secret. This is done offline.
    local customkcfg="$(mktemp)"
    kubectl -n "${K8S_NS}" create secret generic \
        "$CUSTOM_HELM_SECRET_KEY" \
        "${ckcfg_args[@]}" > "$customkcfg"
    echo "$customkcfg"
}
_create_k8s_secret () {
    local customkcfg="$1"
    _load_k8s_ns
    kubectl -n "${K8S_NS}" apply -f "$customkcfg"
}

_usage () {
    cat <<EOUSAGE
Usage: $0 [OPTIONS] COMMAND

Commands:

    k8s_ns          Print out the default Kubernetes namespace for custom deploys
                    (\$deployment_identifier from tags.sh). Requires -t option.

    get_values NAME [..]
                    Retrieve the contents of the Kubernetes secret (secret
                    'custom-deploy.\$HELM_RELEASE', key NAME) for a custom deploy.
                    Outputs a temporary file with the contents.  Requires -R option.
                    (NAMEs: 'values', 'pinned-values')

    edit NAME [..]
                    Retrieve the Kubernetes secrets with your custom configs, open them
                    in your default text editor. Once you close your text editor, the
                    file will be uploaded back to the Kubernetes secret.
                    (NAMEs: 'values', 'pinned-values')

    
    upload NAME [..]
                    Process template '\$HELM_CHART/custom-deploy.\$CUSTOM_HELM_NAME.NAME.tpl'
                    with the tags.sh file specified, and upload the result to a Kubernetes
                    secret \$CUSTOM_HELM_SECRET_KEY.

Options:
    -t FILE         The tags.sh script to load values from (\$TAGS_FILE)
    -R NAME         The name of the Helm release (\$HELM_RELEASE)
    -C PATH         The path to the directory of the Helm chart (\$HELM_CHART)
    -N NAMESPACE    The Kubernetes namespace to manage secrets in (\$K8S_NS)
    -n              Dry-run mode
    -h              This screen

Environment variables:
    CUSTOM_HELM_SECRET_KEY
                The name of the Kubernetes secret to create ('custom-deploy.\$HELM_RELEASE')
    CUSTOM_HELM_NAME
                A namespace for default template and tag files ('dev')

Examples:

 $ $0 -R HELM_CHART -t helm/HELM_CHART/tags.sh.default get_values values
 $ $0 -R HELM_CHART -t helm/HELM_CHART/tags.sh.default get_values pinned-values

 $ $0 -R HELM_CHART -t helm/HELM_CHART/tags.sh.default edit values
 $ $0 -R HELM_CHART -t helm/HELM_CHART/tags.sh.default edit pinned-values

 $ $0 -R HELM_CHART -t helm/HELM_CHART/tags.sh.default k8s_ns

 $ $0 -R HELM_CHART -C helm/HELM_CHART -t helm/HELM_CHART/tags.sh.default upload values pinned-values

EOUSAGE
    exit 1
}


HELM_CHART="${HELM_CHART:-}"
HELM_RELEASE="${HELM_RELEASE:-}"
TAGS_FILE="${TAGS_FILE:-}"
_dry_run="0"
while getopts "C:R:N:t:nh" arg ; do
    case "$arg" in
        C)          HELM_CHART="$OPTARG" ;;
        R)          HELM_RELEASE="$OPTARG" ;;
        N)          export K8S_NS="$OPTARG" ;;
        t)          TAGS_FILE="$OPTARG" ;;
        n)          _dry_run="1" ;;
        h)          _usage ;;
        *)          _die "Unknown argument '$arg'" ;;
    esac
done
shift $((OPTIND-1))


# Attempt to retrieve a secret from K8s which is the combination of the name of this
# helm release, and ".custom-deploy". This is a custom set of values.yaml to add to the
# Helm commands.
CUSTOM_HELM_SECRET_KEY="${CUSTOM_HELM_SECRET_KEY:-custom-deploy.$HELM_RELEASE}"
CUSTOM_HELM_NAME="${CUSTOM_HELM_NAME:-dev}"

if [ $# -lt 1 ] ; then
    _usage
fi

cmd="$1"; shift
_cmd_"$cmd" "$@"
