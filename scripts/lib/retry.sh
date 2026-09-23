# Shell-level retry, sourced by the scripts that download.
#
# curl's own --retry does not cover every transient failure: curl 7.68 treats
# error 56 (connection reset while receiving) as final, and large downloads on
# this network hit it now and then. apptainer pull has no retry at all.
#
#   retry <attempts> <first delay s> <command...>
#       Runs the command until it succeeds, doubling the delay after each
#       failure. Returns the command's last exit status.
#
#   fetch_url <url> <dest>
#       curl into <dest>.part with resume (-C -), under retry; renames to <dest>
#       only when the transfer completed, so a half file never looks finished.

retry() {
    local attempts=$1 delay=$2 n=1 rc
    shift 2
    while :; do
        "$@" && return 0
        rc=$?
        if [ "$n" -ge "$attempts" ]; then
            echo "retry: giving up after $n attempts (exit $rc): $*" >&2
            return "$rc"
        fi
        echo "retry: attempt $n failed (exit $rc), again in ${delay}s: $*" >&2
        sleep "$delay"
        n=$((n + 1))
        delay=$((delay * 2))
    done
}

fetch_url() {
    local url=$1 dest=$2
    retry "${RETRY_ATTEMPTS:-6}" "${RETRY_DELAY:-10}" \
        curl -fL --connect-timeout 30 -C - -o "${dest}.part" "$url" || return
    mv "${dest}.part" "$dest"
}
