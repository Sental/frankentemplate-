#!/usr/bin/env bash
# =============================================================================
# Runs inside the installer's one-off app container (normally as www-data, in /app).
# install_handoff mounts it and runs: bash /tmp/install-timing.sh LOG COMMAND [ARGS]
#
# COMMAND (bin/magento install) runs in the foreground with the terminal, as it would
# without this script. Beside it, a loop reads /proc every 0.25 s and appends to LOG a
# line when each process the installer starts begins and ends, and a sample of what it's
# doing every 2 s while it runs (every 10 s for the installer itself):
#   state   R on a CPU, S sleeping (network, a lock, a timer), D waiting on the disk
#   cpu     user and system CPU seconds so far. Rising user time is PHP working;
#           rising system time, or D, points at file I/O.
#   io      bytes through read()/write() (rchar, wchar) and from storage (read, write)
#   wchan   the kernel function it's waiting in (- while it's running)
# Every line also has the load average, available memory and CPU/IO pressure.
#
# It doesn't wrap, signal or wait on the processes it watches, so a step the installer
# stops for its timeout is stopped as it would be anyway. (A php wrapper would have been
# killed in the step's place, leaving the real step running.) So there are no exit
# codes: a timed-out step shows as one that lasted its timeout, and the installer says
# "exceeded the timeout".
#
# Command lines are cut to their first four words, so a value given to config:set, such
# as the SMTP password, never reaches the log. Within those four, a NAME=value whose name
# looks secret, and the user:password@ of a URL (Composer can hand git a token that way),
# are masked.
#
# The stack runs the installer as www-data. Any user other than www-data or root is
# pointed out on the terminal and in LOG: it's for whoever runs setup to decide about.
# =============================================================================
set -uo pipefail
shopt -s nocasematch

log_file=$1
shift

untimed() {
    printf '[install-timing] WARNING: %s, so this run is NOT timed. The installer runs anyway.\n' "$1" >&2
    shift
    exec "$@"
}

[ -n "${EPOCHREALTIME:-}" ] || untimed "this bash has no EPOCHREALTIME (it needs bash 5)" "$@"
{ mkdir -p "$(dirname "$log_file")" && : >> "$log_file"; } 2>/dev/null || untimed "can't write $log_file" "$@"

CLK_TCK=$(getconf CLK_TCK 2>/dev/null) || CLK_TCK=100
readonly STEP_EVERY=2000000 INSTALLER_EVERY=10000000

me=$(id -un 2>/dev/null) || me="uid $(id -u)"
user_note=""
case "$me" in
    root|www-data) ;;
    *) user_note="the installer is running as '$me' (uid $(id -u)), not www-data or root. The stack runs it as www-data, so the files this install writes will belong to '$me' instead." ;;
esac

# Per-process I/O counters exist only in a kernel built with task I/O accounting; when
# /proc/self/io is missing, the samples say so instead of calling it unreadable.
if [ -e /proc/self/io ]; then io_accounting=1; else io_accounting=0; fi

# Pressure: the container's own cgroup files if the kernel offers them, else the whole
# machine's (under Docker Desktop, its VM's).
psi_cpu="" psi_io="" psi_scope="unavailable"
if read -r _ < /sys/fs/cgroup/cpu.pressure 2>/dev/null; then
    psi_cpu=/sys/fs/cgroup/cpu.pressure psi_io=/sys/fs/cgroup/io.pressure psi_scope="this container's cgroup"
elif read -r _ < /proc/pressure/cpu 2>/dev/null; then
    psi_cpu=/proc/pressure/cpu psi_io=/proc/pressure/io psi_scope="the whole machine"
fi

# --- formatting (each sets the variable named by its first argument) -----------
secs() { printf -v "$1" '%d.%ds' $(($2 / 1000000)) $(($2 / 100000 % 10)); }
ticks() { printf -v "$1" '%d.%02ds' $(($2 / CLK_TCK)) $(($2 % CLK_TCK * 100 / CLK_TCK)); }
mib() { printf -v "$1" '%d.%dMiB' $(($2 / 1048576)) $(($2 % 1048576 * 10 / 1048576)); }

# pressure FILE VAR: the "some avg10" figure, the share of the last 10 s in which at least
# one task was stalled waiting for that resource.
pressure() {
    local line
    if [ -n "$1" ] && read -r line < "$1" 2>/dev/null; then
        line=${line#*avg10=}
        printf -v "$2" '%s%%' "${line%% *}"
    else
        printf -v "$2" 'n/a'
    fi
}

# system_now: sets sys to the machine's state now.
system_now() {
    local l1 l2 l3 key value mem='?' cpu io
    read -r l1 l2 l3 _ < /proc/loadavg
    while read -r key value _; do
        if [ "$key" = MemAvailable: ]; then mem=$((value / 1024)); break; fi
    done < /proc/meminfo
    pressure "$psi_cpu" cpu
    pressure "$psi_io" io
    sys="load=$l1,$l2,$l3 memavail=${mem}MiB psi.cpu=$cpu psi.io=$io"
}

# emit EVENT FIELDS: appends one line, stamped with the tick's time (t) and state (sys).
emit() {
    local ts
    printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' "${t:0:-6}"
    printf '%s.%sZ %-6s %s %s\n' "$ts" "${t: -6:3}" "$1" "$2" "$sys" >> "$log_file"
}

# short_command: sets cmd from args, the first four words of the command line.
short_command() {
    local -a words kept=()
    local word
    read -r -a words <<< "${args[*]}"
    [ "${words[0]:-}" != "" ] && [ "${words[0]##*/}" = env ] && words=("${words[@]:1}")
    for word in "${words[@]:0:4}"; do
        [[ $word == *=* && ${word%%=*} =~ (pass|secret|token|key) ]] && word="${word%%=*}=***"
        [[ $word =~ ^(.*://)[^/@]+@(.*)$ ]] && word="${BASH_REMATCH[1]}***@${BASH_REMATCH[2]}"
        kept+=("$word")
    done
    cmd="${kept[*]}"
    if [ ${#words[@]} -gt 4 ]; then cmd+=" (+$((${#words[@]} - 4)) more)"; fi
}

# sample PID: what the process is doing now.
sample() {
    local pid=$1 stat rest key value io wchan="" rchar=0 wchar=0 rb=0 wb=0 after user_cpu sys_cpu
    local -a f
    read -r stat < "/proc/$pid/stat" 2>/dev/null || return 0
    rest=${stat##*) }
    read -r -a f <<< "$rest"
    # /proc/PID/io is readable only by the process's own user, or root.
    if [ "$io_accounting" = 0 ]; then
        io="io=n/a(kernel-has-no-io-accounting)"
    elif { while read -r key value; do
            case "$key" in
                rchar:) rchar=$value ;;
                wchar:) wchar=$value ;;
                read_bytes:) rb=$value ;;
                write_bytes:) wb=$value ;;
            esac
        done < "/proc/$pid/io"; } 2>/dev/null; then
        mib rchar "$rchar"; mib wchar "$wchar"; mib rb "$rb"; mib wb "$wb"
        io="rchar=$rchar wchar=$wchar read=$rb write=$wb"
    else
        io="io=unreadable"
    fi
    # 0 for a task that's running (state R) rather than waiting.
    read -r wchan < "/proc/$pid/wchan" 2>/dev/null
    if [ -z "$wchan" ] || [ "$wchan" = 0 ]; then wchan=-; fi
    secs after $((t - start[$pid]))
    ticks user_cpu "${f[11]:-0}"
    ticks sys_cpu "${f[12]:-0}"
    emit sample "pid=$pid after=$after state=${f[0]:-?} cpu.user=$user_cpu cpu.sys=$sys_cpu $io wchan=$wchan"
    next[$pid]=$((t + every[$pid]))
}

# ended PID: true once the process is gone, or is a zombie its parent hasn't collected yet.
ended() {
    local stat="" rest
    read -r stat < "/proc/$1/stat" 2>/dev/null
    rest=${stat##*) }
    [ -z "$stat" ] || [ "${rest:0:1}" = Z ]
}

# watch_installer SCRIPT_PID: the loop, run in the background. known (the processes
# already running before the installer) is filled before it's started.
#
# Only the installer and its descendants are logged. Docker runs the app service's health
# check in this one-off container too (compose run keeps it), and a process Docker starts
# from outside has parent 0, so it's never one of them.
watch_installer() {
    export TZ=UTC
    local script_pid=$1 self=$BASHPID dir pid ppid stat rest up age owner cmd after t sys
    local -A start=() next=() every=() name=() family=()
    local -a f args
    known[$self]=1
    family[$script_pid]=1

    # The installer exits just before this runs, so a step can have ended since the last
    # tick: only one still there was left running.
    # shellcheck disable=SC2317,SC2329  # reached through the trap
    finish() {
        t=${EPOCHREALTIME//[!0-9]/}
        system_now
        for pid in "${!start[@]}"; do
            secs after $((t - start[$pid]))
            if ended "$pid"; then
                emit end "pid=$pid after=$after cmd=\"${name[$pid]}\""
            else
                emit left "pid=$pid after=$after cmd=\"${name[$pid]}\" (still running when the installer exited)"
            fi
        done
    }
    trap 'finish; exit 0' TERM

    while :; do
        t=${EPOCHREALTIME//[!0-9]/}
        system_now
        for dir in /proc/[0-9]*; do
            pid=${dir#/proc/}
            [ -n "${known[$pid]:-}" ] && continue
            if [ -n "${start[$pid]:-}" ]; then
                [ "$t" -ge "${next[$pid]}" ] && sample "$pid"
                continue
            fi
            read -r stat < "$dir/stat" 2>/dev/null || continue
            rest=${stat##*) }
            read -r -a f <<< "$rest"
            ppid=${f[1]:-0}
            # Not the installer's: a health check, a docker exec, this loop's own sleep.
            if [ -z "${family[$ppid]:-}" ]; then known[$pid]=1; continue; fi
            family[$pid]=1
            mapfile -d '' -t args < "$dir/cmdline" 2>/dev/null || continue
            [ ${#args[@]} -gt 0 ] || continue
            # Symfony starts each step as sh -c 'exec bin/magento …', which holds the whole
            # command, values included, in one argument. The exec replaces it within a
            # millisecond, so it's picked up on a later tick, as php.
            case "${args[0]##*/}" in
                sh|bash|dash) [ "${args[1]:-}" = -c ] && continue ;;
            esac
            # When it started, from the kernel (10 ms), not from when this loop noticed it.
            read -r up _ < /proc/uptime
            up=${up//./}
            age=$((up * 10000 - ${f[19]:-0} * 1000000 / CLK_TCK))
            [ "$age" -ge 0 ] || age=0
            start[$pid]=$((t - age))
            if [ "$ppid" = "$script_pid" ]; then every[$pid]=$INSTALLER_EVERY; else every[$pid]=$STEP_EVERY; fi
            next[$pid]=$((start[$pid] + every[$pid]))
            short_command
            name[$pid]=$cmd
            if [ -O "$dir" ]; then owner=$me; else owner=$(stat -c %U "$dir" 2>/dev/null) || owner=""; fi
            # A process that ended before its user could be read isn't flagged: that says
            # nothing about who it ran as.
            case "$owner" in
                "") owner="?(ended-before-it-could-be-read)" ;;
                root|www-data) ;;
                *) owner+="(not-www-data-or-root)" ;;
            esac
            emit start "pid=$pid ppid=$ppid user=$owner cmd=\"$cmd\""
        done
        for pid in "${!start[@]}"; do
            ended "$pid" || continue
            secs after $((t - start[$pid]))
            emit end "pid=$pid after=$after cmd=\"${name[$pid]}\""
            unset "start[$pid]" "next[$pid]" "every[$pid]" "name[$pid]"
        done
        sleep 0.25
    done
}

# --- the run --------------------------------------------------------------------
# The header and footer take UTC from date -u. Exporting TZ here would hand it to the
# installer; the watcher sets it only in its own subshell.
run_start=${EPOCHREALTIME//[!0-9]/}
mem_total='?'
while read -r key value _; do
    if [ "$key" = MemTotal: ]; then mem_total=$((value / 1024)); break; fi
done < /proc/meminfo
{
    printf '\n=== installer run, started %sZ ===\n' "$(date -u -d "@${run_start:0:-6}" +%Y-%m-%dT%H:%M:%S)"
    printf 'command: %s\n' "$*"
    printf 'user: %s (uid %s)\n' "$me" "$(id -u)"
    [ -n "$user_note" ] && printf 'NOTE: %s\n' "$user_note"
    printf 'cpus: %s, memory: %s MiB, pressure: %s, per-process io: %s\n' "$(nproc 2>/dev/null || echo '?')" \
        "$mem_total" "$psi_scope" "$([ "$io_accounting" = 1 ] && echo available || echo 'not in this kernel')"
    printf 'Times are UTC. A start time comes from the kernel (10 ms); an end is seen within 0.25 s, and a process shorter than that may not appear.\n'
} >> "$log_file"

if [ -n "$user_note" ]; then
    printf '\n[install-timing] NOTE: %s\n\n' "$user_note" >&2
fi

# Taken here, not in the background loop, so the installer can't start before it.
declare -A known=()
for dir in /proc/[0-9]*; do known[${dir#/proc/}]=1; done

watch_installer "$$" 2>> "$log_file" &
watcher=$!
trap 'kill "$watcher" 2>/dev/null' EXIT
# A handler, not '' (which the installer would inherit): Ctrl-C still reaches the
# installer, and this script lives on to record how the run ended.
trap ':' INT

"$@"
status=$?

kill -TERM "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
run_end=${EPOCHREALTIME//[!0-9]/}
took=""
secs took $((run_end - run_start))
printf '=== installer exited %sZ with status %s, after %s ===\n' \
    "$(date -u -d "@${run_end:0:-6}" +%Y-%m-%dT%H:%M:%S)" "$status" "$took" >> "$log_file"
exit "$status"
