#!/bin/sh
# =============================================================================
# log-tailer (dev): streams every Magento log file to stdout, so Dozzle shows it.
#
# It follows every *.log under var/log and var/debug, including files created
# after it starts, and prefixes each line with its file name. The old tailer
# followed a fixed list, so new logs and every *-error.log were invisible
# (FINDINGS F-25).
#
# Every TAIL_RESCAN seconds it rescans the directories. When the set of files
# changes, it restarts `tail` on the new set. A FIFO that stays open keeps the
# labelling awk running across those restarts.
# =============================================================================
set -eu

ROOTS="${TAIL_ROOTS:-/mnt/var/log /mnt/var/debug}"
RESCAN="${TAIL_RESCAN:-10}"
FIFO=/tmp/log-tailer.fifo

rm -f "$FIFO"
mkfifo "$FIFO"
# Hold the FIFO open read-write, so awk never sees end-of-file when one tail exits
# and the next one starts.
exec 3<>"$FIFO"

# `tail -v` prints "==> file <==" before each file's output; awk turns that into a
# per-line label.
awk '
    /^==> .* <==$/ { file = $2; sub(".*/var/", "", file); next }
    NF              { printf "[%s] %s\n", file, $0; fflush() }
' <"$FIFO" &

files=""
tail_pid=""

list_logs() {
    # shellcheck disable=SC2086 # ROOTS is a space-separated list by design
    find $ROOTS -type f -name '*.log' 2>/dev/null | sort
}

trap '[ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null; exit 0' TERM INT

while :; do
    current=$(list_logs)
    if [ "$current" != "$files" ]; then
        if [ -n "$tail_pid" ]; then kill "$tail_pid" 2>/dev/null || true; fi
        files=$current
        tail_pid=""
        if [ -n "$files" ]; then
            # -n 0: only lines written from now on. -F: keep following across logrotate.
            # shellcheck disable=SC2086 # one argument per file
            tail -v -n 0 -F $files >"$FIFO" 2>/dev/null &
            tail_pid=$!
            echo "[log-tailer] following $(echo "$files" | wc -l) file(s)"
        fi
    fi
    sleep "$RESCAN"
done
