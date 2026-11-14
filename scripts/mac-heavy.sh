#!/bin/bash
# Run at most HUSHY_HEAVY_SLOTS heavy Mac jobs at a time (default 2; evals with Apple FM or MLX, full
# test suites, release builds, snapshot renders). Apple FM refuses work under memory pressure and the
# founder's live Hushy slows down, so agents queue here instead of all running at once. Two fit a
# 24 GB, 12-core Mac (founder, 2026-10-25: "you can run in parallel"); set HUSHY_HEAVY_SLOTS=1 for the
# old one-at-a-time behaviour.
#
#   scripts/mac-heavy.sh <label> <command…>
#
# A job may hold the lock for at most HUSHY_HEAVY_MAX_SECONDS (default 2700, 45 minutes; 0 means no
# limit). When the limit passes, the job and its children are stopped and the next waiter runs. Without
# it, one hung test run blocks every agent behind it.
#
# First come, first served: each waiter takes a ticket (a file named by arrival time) and may take
# the lock only when its ticket is the oldest live one. The lock is a directory (mkdir is atomic)
# holding the owner's pid. A stale lock is broken by renaming it first (one winner), and the exit
# trap removes the lock only while it still holds our pid.
set -euo pipefail
LABEL="${1:?usage: mac-heavy.sh <label> <command…>}"; shift
LOCK="${HUSHY_HEAVY_LOCK:-/tmp/hushy-mac-heavy.lock}"
QUEUE="$LOCK.queue"
SLOTS="${HUSHY_HEAVY_SLOTS:-2}"
[ "$SLOTS" -ge 1 ] 2>/dev/null || SLOTS=1
# Slot 0 is the old lock path, so a copy of this script from before slots still sees it.
slot_path() { if [ "$1" -eq 0 ]; then echo "$LOCK"; else echo "$LOCK.$1"; fi; }
ME=$$
# A command run from inside a job that already holds the lock (gate.sh queues its own steps here) runs
# straight through. Waiting would wait on itself: on 2026-10-23 a wrapped gate sat deadlocked for 7 hours.
if [ -n "${HUSHY_HEAVY_HOLDER:-}" ]; then
    for i in $(seq 0 $((SLOTS - 1))); do
        if [ "$(cat "$(slot_path "$i")/pid" 2>/dev/null || true)" = "$HUSHY_HEAVY_HOLDER" ]; then exec "$@"; fi
    done
fi
mkdir -p "$QUEUE"
# HUSHY_HEAVY_PRIORITY=1 puts this job ahead of every ordinary waiter (its ticket sorts first);
# use it only for the work the founder has ranked first. It never interrupts a running job.
TICKET="$QUEUE/${HUSHY_HEAVY_PRIORITY:+0}$(date +%s)$(printf '%05d' $((RANDOM % 100000)))-$ME"
echo "$LABEL" > "$TICKET"

break_if_stale() {
    local holder grave slot
    slot="$1"
    holder="$(cat "$slot/pid" 2>/dev/null || true)"
    [ -n "$holder" ] || return 0
    kill -0 "$holder" 2>/dev/null && return 0
    grave="$slot.stale.$ME.$RANDOM"
    mv "$slot" "$grave" 2>/dev/null || return 0
    if [ "$(cat "$grave/pid" 2>/dev/null || true)" = "$holder" ]; then rm -rf "$grave"
    else mv "$grave" "$slot" 2>/dev/null || rm -rf "$grave"; fi
}

# True when this ticket is among the oldest live tickets, one per free slot.
in_line() {
    local t pid ahead=0 busy=0 i
    for i in $(seq 0 $((SLOTS - 1))); do [ -d "$(slot_path "$i")" ] && busy=$((busy + 1)); done
    for t in $(ls "$QUEUE" 2>/dev/null | sort); do
        pid="${t##*-}"
        if ! kill -0 "$pid" 2>/dev/null; then rm -f "$QUEUE/$t"; continue; fi   # dead waiter
        [ "$QUEUE/$t" = "$TICKET" ] && [ "$ahead" -lt $((SLOTS - busy)) ] && return 0
        [ "$QUEUE/$t" = "$TICKET" ] && return 1
        ahead=$((ahead + 1))
    done
    return 0
}

HELD=""
take_slot() {
    local i slot
    for i in $(seq 0 $((SLOTS - 1))); do
        slot="$(slot_path "$i")"
        if mkdir "$slot" 2>/dev/null; then HELD="$slot"; return 0; fi
    done
    return 1
}

release() {
    rm -f "$TICKET"
    [ -n "$HELD" ] && [ "$(cat "$HELD/pid" 2>/dev/null || true)" = "$ME" ] && rm -rf "$HELD"
    return 0
}
trap release EXIT
# A signal must stop a queued wrapper. Merely releasing its ticket then returning
# lets it enter the job later when the queue becomes empty.
trap 'exit 130' INT
trap 'exit 143' TERM

waited=0
until in_line && take_slot; do
    for i in $(seq 0 $((SLOTS - 1))); do break_if_stale "$(slot_path "$i")"; done
    if [ $((waited % 60)) -eq 0 ]; then
        running="$(for i in $(seq 0 $((SLOTS - 1))); do cat "$(slot_path "$i")/label" 2>/dev/null || true; done | paste -sd, - || true)"
        echo "mac-heavy: waiting for ${running:-?} (${waited}s; $(ls "$QUEUE" | wc -l | tr -d ' ') in line)" >&2
    fi
    sleep 5; waited=$((waited + 5))
done
echo "$ME" > "$HELD/pid"; echo "$LABEL" > "$HELD/label"
rm -f "$TICKET"
export HUSHY_HEAVY_HOLDER="$ME"

# Swift Testing starts every test of a run at once unless told how many may run together. With 4,000 of
# them the cooperative thread pool is a queue several seconds long for the first six seconds of a run, so
# a timer that should fire in 5 ms fires seconds late and a short-budget test reads it as a timeout
# (measured with a heartbeat task: worst gap 4 to 6 s unbounded, 0.18 s at a width of 3, 6, 8 or 12 on
# a 12-core Mac; a full run takes 62 s at 8 against 60 s unbounded). Two thirds of the cores, at least 4.
# An explicit value in the environment wins.
if [ -z "${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-}" ]; then
    cpus="$(sysctl -n hw.ncpu 2>/dev/null || echo 6)"
    width=$((cpus * 2 / 3 / SLOTS)); [ "$width" -lt 4 ] && width=4
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$width"
fi

MAX="${HUSHY_HEAVY_MAX_SECONDS:-2700}"
if [ "$MAX" -le 0 ]; then "$@"; exit $?; fi
set -m                                   # the job gets its own process group, so the limit reaches its children
"$@" <&0 &
JOB=$!
( sleep "$MAX"
  echo "mac-heavy: $LABEL ran longer than ${MAX}s; stopping it" >&2
  kill -TERM -- "-$JOB" 2>/dev/null; sleep 10; kill -KILL -- "-$JOB" 2>/dev/null ) &
WATCH=$!
trap 'kill -TERM -- "-$JOB" 2>/dev/null; exit 130' INT
trap 'kill -TERM -- "-$JOB" 2>/dev/null; exit 143' TERM
status=0; wait "$JOB" || status=$?
kill -TERM -- "-$WATCH" 2>/dev/null || true
exit "$status"
