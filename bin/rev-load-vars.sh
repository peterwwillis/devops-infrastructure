#!/usr/bin/env sh
# rev-load-vars.sh - Load in variables from files, using reverse path hierarchy
# Usage:
#   1. Go to a directory hierarchy with DIRENVSH_RC files in parent directories
#   2. Run the command: rev-load-vars.sh
# 
# Pass option "-s" to use 'set' to export environment variables, minus ones
# exported by the shell that would mess with your parent script.
#
# Pass any other arguments and they will be executed as an external program
# (inheriting the environment variables set by this script).

set -eu
[ "${DEBUG:-0}" = "1" ] && set -x


# Override this to change what file we look for env vars in
DIRENVSH_RC="${DIRENVSH_RC:-.envrc}"


_log () { # usage: _log MSG [replacement-1 [..]]
    [ "$__verbose_mode" = "1" ] || return 0
    msg="$1"; shift
    [ "${QUIET:-0}" = "0" ] || return 0
    printf "%s: $msg" "$0" "$@" 1>&2
}
_rloadfiles_recurse_precedence () {
    direnvsh_level=$((${direnvsh_level:--1}+1))
    # shellcheck disable=SC2166
    if [ "${DIRENVSH_STOP:-0}" = "1" ] || [ -e "$1/.stopdirenvsh" ] \
       || [ -n "${DIRENVSH_STOPDIR:-}" -a "$1" = "${DIRENVSH_STOPDIR:-}" ]; then
        _log "Found stop dir ('%s'), ending processing\n" "$1"
        return
    fi
    [ ! "$3" = "far" ] || _rloadfiles_recurse_order "$1" "$2" "$3" "$4"
    _rloadfile "$1" "$2"
    direnvsh_level=$((direnvsh_level-1))
    [ ! "$3" = "close" ] || _rloadfiles_recurse_order "$1" "$2" "$3" "$4"
}
_rloadfiles_recurse_order () {
    if [ ! "$1" = "/" ] ; then
        if [ "$4" = "backward" ] ; then
            _rloadfiles_recurse_precedence "$(dirname "$1")" "$2" "$3" "$4"
        elif [ "$4" = "forward" ] ; then
            for _dir in "$1"/* ; do
                [ -d "$_dir" ] || continue
                _rloadfiles_recurse_precedence "$_dir" "$2" "$3" "$4"
            done
        fi
    fi
}
_rloadfile () {
    direnvsh_cwd="$1" direnvsh_file="$2"
    if [ -e "$direnvsh_cwd/$direnvsh_file" ] ; then
        _log "Loading file '%s'" "$direnvsh_cwd/$direnvsh_file"
        _read_tfvars < "$direnvsh_cwd/$direnvsh_file"
    fi
}
_read_tfvars () {
    while IFS='=' read -r key val; do
        # Skip comments
        [ "${key##\#*}" ] || continue
        set +e
        ## Replace text '${FOO}' with value of '$FOO'
        #_replaceval_ind "$key" "$val" '^.*${[a-zA-Z0-9_]\+}' '^.*${\([a-zA-Z0-9_]\+\)}.*$'
        ## Replace text '$FOO' with value of '$FOO'
        #_replaceval_ind "$key" "$val" '^.*$[a-zA-Z0-9_]\+' '^.*$\([a-zA-Z0-9_]\+\).*$'
        # Strip leading whitespace
        key="${key#"${key%%[![:space:]]*}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        # Skip trailing whitespace
        key="${key%"${key##*[![:space:]]}"}"   
        val="${val%"${val##*[![:space:]]}"}"   
        # Strip quotes from values
        val="${val#"${val%%[!\"]*}"}"
        val="${val%"${val##*[!\"]}"}"
        # Bash-ism; avoid for POSIX
        #key="${key//[^A-Za-z0-9_]/_}"
        key="$(printf "%s" "$key" | tr -c 'a-zA-Z0-9_' '_')"
        eval "export \"$key=$val\""
        set -e
        _log "Found k '%s', v '%s'\n" "$key" "$val"
    done
}
_replaceval_ind () {
    _k="$1" _v="$2" _idxregex="$3" _regex="$4" _matchidx='' _match='' _new='' _idx='' _begin='' _end=''
    while : ; do
        _matchidx="$(expr "$_v" : "$_idxregex")"
        if [ ! "$_matchidx" = "0" ] ; then
            _match="$(expr "$_v" : "$_regex")"
            eval _new="\${$_match:-}"
            _idx=$((_matchidx-(${#_match}+1)))
            # shellcheck disable=SC2308
            _begin="$(expr substr "$_v" 1 $_idx)"
            # shellcheck disable=SC2308
            _end="$(expr substr "$_v" $((_matchidx+1)) 99999999)"
            _v="${_begin}${_new}${_end}"
            export "$_k=$_v"
        else
            export "$_k=$_v"
            break
        fi
    done
}

_usage () {
    cat <<EOUSAGE
Usage: $0 [OPTIONS] [ARGS ..]

Looks in parent directories for a file $DIRENVSH_RC
(Override this value as \$DIRENVSH_RC), detects the values
in the file, and sets them as environment variables.

Stops processing when it finds a directory with a file .stopdirenvsh
(overrideable with \$DIRENVSH_STOPDIR).

If ARGS are passed, they are executed as an external program and
program arguments, after environment variables have been set.

Options:
    -s          Export shell-comparible values
    -v          Verbose mode (log found variables to stderr)
    -h          This screen
EOUSAGE
    exit 1
}

__help_mode=0 __verbose_mode=0 __export_mode=0
while getopts "hvs" args ; do
    case "$args" in
        h)      __help_mode=1 ;;
        v)      __verbose_mode=1 ;;
        s)      __export_mode=1 ;;
        *)      _usage "Invalid option '$args'" ;;
    esac
done
shift $((OPTIND-1))


_rloadfiles_recurse_precedence "$(pwd)" "$DIRENVSH_RC" "far" "backward"


# shellcheck disable=SC2166
if [ "$__help_mode" = "1" ] ; then
    _usage

elif [ "$__export_mode" = "1" ] ; then
    # This is problematic; export is more what we want
    #set | grep -v -E "^(BASH_|EUID|UID|GROUPS|PIPESTATUS|PPID|SHELLOPTS|PATH)"
    export

elif [ $# -gt 0 ] ; then
    exec "$@"

fi
