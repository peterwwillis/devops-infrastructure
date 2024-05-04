#!/usr/bin/env bash
# shellcheck disable=SC2317,SC1090,SC1091
set -eu
[ "${DEBUG:-0}" = "1" ] && set -x

# deploy.conf can have the following values:
#   PRODUCTS=
#       - A list of default products to deploy if you do not pass a specific one.
#   DOMAINS=
#       - A list of default domains to deploy if you do not pass a specific one.
#   TENANTS=
#       - A list of default tenants to deploy if you do not pass a specific one.
#   ENVS=
#       - A list of default environments to deploy if you do not pass a specific one.
#   MODULES=
#       - A list of default modules to deploy, in order, if you do not pass a specific one.
#   MODULE_TYPE=
#       - To be used in a deploy.conf in a module directory. Possible values:
#           - helm
#           - terraform
#           - make
#   TAGS=
#       - A comma-separated list of strings (no spaces allowed). Used to identify specific
#         modules with specific criteria (--include-tags, --exclude-tags)
# 
# You can place a deploy.conf in the following directories and it will override
# the previous deploy.conf values:
#   - $ROOTDIR/env/deploy.conf
#   - $ROOTDIR/env/$domain/deploy.conf
#   - $ROOTDIR/env/$domain/$tenant/deploy.conf
#   - $ROOTDIR/env/$domain/$tenant/$env/deploy.conf
#   - $ROOTDIR/env/$domain/$tenant/$module/deploy.conf

ROOTDIR="${ROOTDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)}"
TMPDIR="${TMPDIR:-/tmp}"

_die () { printf "%s\n" "%s: %s: %s" "$(basename "$0")" "Error" "$@" 1>&2 ; exit 1 ; }
_info () { [ "${_quiet:-0}" = "1" ] || printf "%s\n" "%s: %s: %s" "$(basename "$0")" "Info" "$@" 1>&2 ; }
_usage () {
    cat <<EOUSAGE
Usage: $0 [OPTIONS] CMD [..]

Commands:
    deploy [OPTIONS] [TENANT [ENVIRONMENT [MODULE]]]
      Options:
        -p,--product NAME       Run deploy on a given product
        -d,--domain NAME        Run deploy on a given domain
        -t,--tenant NAME        Run deploy on a given tenant
        -e,--environment NAME   Run deploy on a given environment
        -m,--module NAME        Run deploy on a given module
        --k8s-ns NAME           Exports K8S_NS=NAME
        -P,--terraform-plan     Run 'plan' step for Terraform modules
        -A,--terraform-apply    Run 'apply' step for Terraform modules
        --no-terraform          Do not run Terraform modules
        --no-helm               Do not run Helm modules

    custom_deploy [OPTIONS]
      Options:
        -p,--product NAME       Run deploy on a given product
        -d,--domain NAME        Run deploy on a given domain
        -t,--tenant NAME        Run deploy on a given tenant
        -e,--environment NAME   Run deploy on a given environment
        -m,--module NAME        Run deploy on a given module
        --tags-file FILE        A shell script to load as tags.sh
        --k8s-ns NAME           Exports K8S_NS=NAME
        --no-trigger-ci         Disable triggering CI/CD build


    list [OPTIONS] [TENANT [ENVIRONMENT [MODULE]]]
      Options:
        -p,--product NAME       Run deploy on a given product
        -d,--domain NAME        Run deploy on a given domain
        -t,--tenant NAME        Run deploy on a given tenant
        -e,--environment NAME   Run deploy on a given environment
        -m,--module NAME        Run deploy on a given module

Global Options:
    -f          Force mode (skip all failures)
    -q          Quiet mode
    --include-tags TAG[,..]
                Only process modules that have a TAGS= variable which 
                contains TAG.
    --exclude-tags TAG[,..]
                Do not process modules that have a TAGS= variable
                which contains TAG. Exclude is processed after include,
                for safety.
    --dry-run   Go through expected steps without executing commands
    -h|--help   This usage screen

Examples:

    - Run 'terraform plan' on all modules (in order) for a given tenant and
      environment, ignoring any failed plan runs:

        $ ./bin/deploy.sh -f deploy -p PRODUCT -d DOMAIN \\
            -t TENANT -e ENVIRONMENT \\
            --terraform-plan

    - List the modules for a given tenant/environment:

        $ ./bin/deploy.sh -q list -d DOMAIN \\
            -t TENANT -e ENVIRONMENT
EOUSAGE
    exit 1
}

_cmd_list () {
    # Note: these are supposed to be globals, not locals
    _list_modules_enabled=1
    while : ; do # Custom arg-parsing so we can use longopts
        [ $# -gt 0 ] || break
        case "$1" in
            -d|--domain)            shift; _deploy_domains="$1" ;;
            -p|--product)           shift; _deploy_products="$1" ;;
            -t|--tenant)            shift; _deploy_tenants="$1" ;;
            -e|--environment)       shift; _deploy_envs="$1" ;;
            -m|--module)            shift; _deploy_modules="$1" ;;
            -h|-\?|--help)          _usage ;;
            --)                     shift; break ;;
            -*)                      _die "Invalid argument: '$1'" ;;
            *)                      break;
        esac
        shift
    done
    _walk_configs "$@"
}

_cmd_deploy () {
    # Note: these are supposed to be globals, not locals
    _deploy_modules_enabled=1 # This function always deploys modules
    while : ; do # Custom arg-parsing so we can use longopts
        [ $# -gt 0 ] || break
        case "$1" in
            -P|--terraform-plan)    _deploy_tf_plan=1 ;;
            -A|--terraform-apply)   _deploy_tf_apply=1 ;;
            -d|--domain)            shift; _deploy_domains="$1" ;;
            -p|--product)           shift; _deploy_products="$1" ;;
            -t|--tenant)            shift; _deploy_tenants="$1" ;;
            -e|--environment)       shift; _deploy_envs="$1" ;;
            -m|--module)            shift; _deploy_modules="$1" ;;
            --k8s-ns)               shift; _deploy_k8s_ns="$1" ;;
            --no-terraform)         _deploy_no_tf=1 ;;
            --no-helm)              _deploy_no_helm=1 ;;
            -h|-\?|--help)          _usage ;;
            --)                     shift; break ;;
            -*)                      _die "Invalid argument: '$1'" ;;
            *)                      break;
        esac
        shift
    done

    if [ -n "${_deploy_k8s_ns:-}" ] ; then
        export K8S_NS="$_deploy_k8s_ns"
    fi

    _walk_configs "$@"
}

_cmd_custom_deploy () {
    # Note: these are supposed to be globals, not locals
    _custom_deploy_enabled=1
    local _deploy_trigger_ci=1
    while : ; do # Custom arg-parsing so we can use longopts
        [ $# -gt 0 ] || break
        case "$1" in
            -d|--domain)            shift; _deploy_domains="$1" ;;
            -p|--product)           shift; _deploy_products="$1" ;;
            -t|--tenant)            shift; _deploy_tenants="$1" ;;
            -e|--environment)       shift; _deploy_envs="$1" ;;
            -m|--module)            shift; _deploy_modules="$1" ;;
            --k8s-ns)               shift; _deploy_k8s_ns="$1" ;;
            --no-trigger-ci)        _deploy_trigger_ci=0 ;;
            -h|-\?|--help)          _usage ;;
            --)                     shift; break ;;
            -*)                      _die "Invalid argument: '$1'" ;;
            *)                      break;
        esac
        shift
    done

    if [ -n "${_deploy_k8s_ns:-}" ] ; then
        export K8S_NS="$_deploy_k8s_ns"
        _info "Overriding K8S_NS from command line: '$K8S_NS'"
    fi

    if [ -n "$K8S_NS" ] ; then
        # Make the namespace if it doesn't exist. Do this once here so we
        # don't have to do it every time in each of the following deploy modules.
        kubectl get ns "${K8S_NS}" || kubectl create namespace "${K8S_NS}"
    fi

    _walk_configs

    if [ ${#FAILED_MODULES[@]} -lt 1 ] ; then
        echo ""
        _info "Custom-deploy configuration uploaded."

        if [ "${_deploy_trigger_ci:-0}" = "1" ] ; then
            declare -a trigger_args=("-n" "$K8S_NS" "-e" "$_deploy_envs" "-w")

            if [ "$_dry_run" = "1" ] ; then
                trigger_args+=("-d")
                _info "Triggering CI/CD dry-run deploy..."
            else
                _info "Triggering CI/CD deploy..."
            fi

            "$ROOTDIR"/bin/cicd.sh trigger_build "${trigger_args[@]}"
        fi
    fi
}


# This function goes through each level of the deployment configs,
# looking for a module to deploy. It load the variables from deploy.conf
# files found along the way, but unloads them after, so each module
# only gets the variables of its parent directories.
_walk_configs () {
    local _domains="${_deploy_domains:-}"
    local _tenants="${1:-$_deploy_tenants}"
    local _environs="${2:-$_deploy_envs}"
    local _modules="${3:-$_deploy_modules}"

    _loadconf "$ROOTDIR/env/deploy.conf"
    domains="${_domains:-$DOMAINS}"
    for domain in $domains ; do
        _info "Processing domain '$domain' ..."
        _loadconf "$ROOTDIR/env/$domain/deploy.conf"
        tenants="${_tenants:-$TENANTS}"
        for tenant in $tenants ; do
            _info "  Processing tenant '$tenant' ..."
            _loadconf "$ROOTDIR/env/$domain/$tenant/deploy.conf"
            environs="${_environs:-$ENVS}"
            for env in $environs ; do
                _info "    Processing environment '$env' ..."
                _loadconf "$ROOTDIR/env/$domain/$tenant/$env/deploy.conf"
                # Just assuming that modules must be configured, somewhere
                modules="${_modules:-$MODULES}"
                for module in $modules ; do
                    # Resolve globbed module names
                    # shellcheck disable=SC2086
                    mods="$( cd "$ROOTDIR/env/$domain/$tenant/$env" && ( ls -d ./$module 2>/dev/null || true ) )"
                    for mod in $mods ; do
                        _process_module "$domain" "$tenant" "$env" "$mod"
                    done
                done
                _unloadconf
            done
            _unloadconf
        done
        _unloadconf
    done
    _unloadconf
}

# Description: Processes an individual module of deployment.
# Logs progress, loads configuration, detects the 'type' of the deployment module,
# determines what function to run for the 'type' of module, runs it, logs errors.
_leave_process_module () {
    unset DEPLOY_DOMAIN DEPLOY_TENANT DEPLOY_ENV DEPLOY_MODULE DEPLOY_MODULE_TYPE DEPLOY_DIR
    _unloadconf
}
_process_module () {
    # Load initial function variables
    local domain="$1" tenant="$2" env="$3" module="$4" ; shift 4
    local dir="$ROOTDIR/env/$domain/$tenant/$env/$module"
    _info "      Processing module '$module' ..."

    # Unset the variables which would be loaded in a module-specific config,
    # incase they were loaded previously in this script somewhere.
    unset MODULE_TYPE

    _loadconf "$dir/deploy.conf"

    # If tags were set, process --exclude-tags and --include-tags
    if [ -n "${_deploy_include_tags:-}" ] ; then
        if [ -z "${TAGS:-}" ] ; then
            _info "        No TAGS were set; skipping module"
            _leave_process_module ; return 0
        fi
        for _include in ${_deploy_include_tags//,/ } ; do
            _matched_tag=0
            for _tag in ${TAGS//,/ } ; do  # Bashism: return TAGS with ',' replaced by ' '
                if [ "$_tag" = "$_include" ] ; then
                    _matched_tag=1
                fi
            done
            if [ "$_matched_tag" = "0" ] ; then
                _info "        Include tag '$_include' not found in module tags; skipping module"
                _leave_process_module ; return 0
            fi
        done
    fi
    if [ -n "${_deploy_exclude_tags:-}" ] && [ -n "${TAGS:-}" ] ; then
        for _tag in ${TAGS//,/ } ; do  # Bashism: return TAGS with ',' replaced by ' '
            for _exclude in ${_deploy_exclude_tags//,/ } ; do
                if [ "$_tag" = "$_exclude" ] ; then
                    _info "        Module tag '$_tag' matches exclude tag '$_exclude'; skipping module"
                    _leave_process_module ; return 0
                fi
            done
        done
    fi

    # Try to detect the module type, if not set in the config.
    # 
    if [ -e "$dir/terraformsh.conf" ] ; then
        # Assume a terraformsh.conf file means terraformsh is run here
        MODULE_TYPE="${MODULE_TYPE:-terraform}"

    elif [ -e "$dir/Makefile" ] ; then
        # Otherwise, detect module type from a Makefile symlink
        linkname="$(basename "$(readlink "$dir/Makefile")")"

        # terraform module type
        if [ "$linkname" = "tf-env-deploy.Makefile" ] || \
           [ "$linkname" = "tf-state.Makefile" ] || \
           [ "$linkname" = "terraformsh.Makefile" ]
        then
            MODULE_TYPE="${MODULE_TYPE:-terraform}"

        # helm module type
        elif [ "$linkname" = "helm-env-deploy.Makefile" ] ; then
            MODULE_TYPE="${MODULE_TYPE:-helm}"

        fi
    fi

    # set variables for child processes
    export DEPLOY_DOMAIN="$domain" DEPLOY_TENANT="$tenant" DEPLOY_ENV="$env" DEPLOY_MODULE="$module"
    export DEPLOY_MODULE_TYPE="${MODULE_TYPE:-}" DEPLOY_DIR="$dir"

    # For the 'list' command
    if [ "${_list_modules_enabled:-0}" = "1" ] ; then
        printf "d=%s\tt=%s\te=%s\tm=%s\tmt=%s\ttags=%s\n" "$domain" "$tenant" "$env" "$module" "${MODULE_TYPE:-}" "${TAGS:-}"

    # For the 'deploy', 'custom_deploy' command
    elif [ "${_deploy_modules_enabled:-0}" = "1" ] || \
         [ "${_custom_deploy_enabled:-0}" = "1" ]
    then
        if [ "${MODULE_TYPE:-}" = "terraform" ] ; then
            _deploy_module_terraform "$@"

        elif [ "${MODULE_TYPE:-}" = "helm" ] ; then
            _deploy_module_helm "$@"

        elif [ "${MODULE_TYPE:-}" = "make" ] || [ -e "$dir/Makefile" ] ; then
            _deploy_module_make "$@"

        else
            _info "          Error: I don't know how to deploy this module!"
            _fail "$domain|$tenant|$env|$module"
        fi
    fi

    _leave_process_module
}

# For Terraform deploys, we need the user to inform us whether to
# run a 'plan', 'apply', or both. Both is very dangerous and should
# not be relied upon.
_deploy_module_terraform () {
    _deploy_no_tf="${_deploy_no_tf:-0}" # Enable tf by default
    # Disable tf plan by default. This is because you may want to run
    #  'apply' without 'plan' first, to approve a previously-run 'plan'.
    _deploy_tf_plan="${_deploy_tf_plan:-0}"
    # Disable tf apply by default
    _deploy_tf_apply="${_deploy_tf_apply:-0}"

    if [ "$_deploy_no_tf" -eq 1 ] ; then
        _info "        Skipping module due to '--no-terraform' option"
    else
        if [ "$_deploy_tf_plan" -eq 1 ]
        then
            _info "        Deploying module ('terraform plan') ..."
            set +e
            tmpfileout="$TMPDIR/tf-plan-out-$RANDOM.log"
            # Passing '-detailed-exitcode' to Terraform here will result in specific return status
            # depending on if there was plan changes or not.
            make -C "$dir" tfsh-plan TF_OPTS="-compact-warnings -detailed-exitcode" QUIET=1 \
                >"$tmpfileout" 2>&1
            ret=$?
            set -e
            if [ "$ret" -eq 2 ] ; then
                EXIT_MESSAGES+=("")
                EXIT_MESSAGES+=("TERRAFORM PLAN CHANGES: domain=$domain tenant=$tenant env=$env module=$module")
                EXIT_MESSAGES+=( "$( _skiplinesre ".*\(Terraform will perform the following actions:\|Changes to Outputs:\|Error:\)" ".*Plan:" <"$tmpfileout" )" )
                EXIT_MESSAGES+=("(Note: If you don't see any output above, something is wrong! Cancel the job and investigate locally)")
            elif [ "$ret" -ne 0 ] ; then
                _info "        Module failed. Output:"
                cat "$tmpfileout" || true
                _fail "$domain|$tenant|$env|$module" "$ret"
            elif [ "$ret" -eq 0 ] ; then
                _info "        Terraform Plan step succeeded with no changes to the plan."

                # Remove any .plan file from the deploy directory if the plan had no changes.
                # TODO: FIXME: there might not be just one .plan file!
                # Can come up with a better solution later if this becomes problematic.
                rm -f "$dir"/tf.*.plan
            fi
            rm -f "$tmpfileout"
        fi

        if [ "$_deploy_tf_apply" -eq 1 ] && \
           [ "$_dry_run" -ne 1 ]
        then
            _info "        Deploying module ('terraform apply') ..."
            found_plan_files="$( ls "$dir"/tf.*.plan 2>/dev/null || true )"
            if [ -z "$found_plan_files" ] ; then
                _info "          Warning: Found no tf.*.plan file in '$dir'; skipping apply step"
            else
                _info "          Found tf plan files: '$found_plan_files'"
                make -C "$dir" tfsh-apply || _fail "$domain|$tenant|$env|$module"
            fi
        fi
    fi
}
_deploy_module_helm () {
    _deploy_no_helm="${_deploy_no_helm:-0}"  # Enable helm by default

    if [ "$_deploy_no_helm" -eq 1 ] ; then
        _info "        Skipping module due to '--no-helm' option"
    else

        if [ "$_dry_run" -eq 1 ] ; then
            _info "         Deploying module ('helm') as a dry-run ..."

            if   [ "${_deploy_modules_enabled:-0}" = "1" ] ; then
                make -C "$dir" dry-deploy || _fail "$domain|$tenant|$env|$module"

            elif [ "${_custom_deploy_enabled:-0}" = "1" ] ; then
                make -C "$dir" dry-custom-deploy || _fail "$domain|$tenant|$env|$module"

            fi

        else
            _info "         Deploying module ('helm') ..."

            if   [ "${_deploy_modules_enabled:-0}" = "1" ] ; then
                make -C "$dir" deploy || _fail "$domain|$tenant|$env|$module"

            elif [ "${_custom_deploy_enabled:-0}" = "1" ] ; then
                make -C "$dir" custom-deploy || _fail "$domain|$tenant|$env|$module"
            fi
        fi

    fi
}
_deploy_module_make () {
    if [ "$_dry_run" -eq 1 ] ; then
        _info "         Deploying module ('make') as a dry-run ..."
        make -C "$dir" -n || _fail "$domain|$tenant|$env|$module"
    else
        _info "         Deploying module ('make') ..."
        make -C "$dir" || _fail "$domain|$tenant|$env|$module"
    fi
}

# Save and restore sets of variables in a stack, so we can maintain
# hierarchy-level variables set throughout a run. Saves variable state
# as _TENANTS_1="$TENANTS" and restores as TENANTS="$_TENANTS_1".
_savevar () { # Usage: _savevar TENANTS
    local _val ; eval "_val=\"\${${1:-}:-}\"" ; eval "_${1}_${_vars_c}=\"${_val}\""
}
_restorevar () { # Usage: _restorevar TENANTS
    eval "${1}=\"\$_${1}_${_vars_c}\""
}
_savevars () {
    _vars_c="$((_vars_c+1))"
    for i in TENANTS ENVS MODULES MODULE_TYPE TAGS ; do
        _savevar "$i"
    done
}
_restorevars () {
    for i in TENANTS ENVS MODULES MODULE_TYPE TAGS ; do
        _restorevar "$i"
    done
    _vars_c="$((_vars_c-1))"
}
_loadconf () { _savevars ; [ ! -e "$1" ] || . "$1" ; }
_unloadconf () { _restorevars ; }
_skiplinesre () { # Usage: echo "TEXT" | _skiplines "SKIPTO_BASICREGEX" "STOPAT_BASICREGEX"
    printline=0 skiptothislinere="$1" stopatthislinere="$2"
    while IFS= read -r line ; do
        if printf "%s\n" "$line" | grep -q -e "$skiptothislinere" ; then printline=1 ; fi
        [ "$printline" -eq 1 ] || continue
        printf "%s\n" "$line"
        if printf "%s\n" "$line" | grep -q -e "$stopatthislinere" ; then break ; fi
    done
}
_fail () {
    local ret=$? module="${1:-}" retstatus="${2:-}"
    if [ -z "$retstatus" ] ; then retstatus="$ret" ; fi
    _info "Detected failure from module '$module'; returned status $retstatus"
    FAILED_MODULES+=("$module")
    [ "$_force" -ne 1 ] || return 0
    return "$ret"
}

#####################################################################

[ $# -gt 0 ] || _usage

declare -a FAILED_MODULES=() EXIT_MESSAGES=()
# shellcheck disable=SC2034
PRODUCTS='' DOMAINS='' TENANTS='' ENVS='' MODULES='' MODULE_TYPE='' TAGS=''
_force=0            _quiet=0            _vars_c=0
_deploy_domains=''  _deploy_products='' _deploy_tenants=''
_deploy_envs=''     _deploy_modules=''  _dry_run=0
_deploy_include_tags=''     _deploy_exclude_tags=''
_deploy_modules_enabled=0   _pin_versions_enabled=0
while : ; do # Custom arg-parsing so we can use longopts
    [ $# -gt 0 ] || break
    case "$1" in
        -f)                 _force=1 ;;
        -q)                 _quiet=1 ;;
        --include-tags)     shift; _deploy_include_tags="$1" ;;
        --exclude-tags)     shift; _deploy_exclude_tags="$1" ;;
        --dry-run)          _dry_run=1 ;;
        -h|-\?|--help)      _usage ;;
        --)                 shift; break ;;
        -*)                 _die "Invalid argument: '$1'" ;;
        *)                  break;
    esac
    shift
done

[ -z "${_deploy_include_tags:-}" ] || \
    export DEPLOYSH_INCLUDE_TAGS="$_deploy_include_tags"

[ -z "${_deploy_exclude_tags:-}" ] || \
    export DEPLOYSH_EXCLUDE_TAGS="$_deploy_exclude_tags"

cmd="$1"; shift
_cmd_"$cmd" "$@"
ret=$?

if [ ${#EXIT_MESSAGES[@]} -gt 0 ] ; then
    echo ""
    for m in "${EXIT_MESSAGES[@]}" ; do _info "  $m" ; done
fi
if [ ${#FAILED_MODULES[@]} -gt 0 ] ; then
    echo ""
    _info "WARNING: The following modules failed to return success:"
    for m in "${FAILED_MODULES[@]}" ; do _info "  $m" ; done
    ret=1
fi
exit $ret
