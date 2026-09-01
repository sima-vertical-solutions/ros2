#!/usr/bin/env bash
#
# Baseline the CPU cost of the running ROS 2 bag recorder (VP-15657).
#
# Reports CPU in *cores* (1.00 = one full core saturated), broken down per
# thread, alongside write throughput and the bag's growth on disk. The
# per-thread split is the interesting part: if the thread doing the mcap chunk
# write is also the thread draining subscriptions, recording is blocking the
# ingest path and a background writer is the fix.
#
# Run it on the robot, with the normal stack up and recording active:
#
#     ./rosbag-cpu-baseline.sh              # 30 s window
#     ./rosbag-cpu-baseline.sh 120          # 2 min window
#     ./rosbag-cpu-baseline.sh 60 -p 1234   # explicit pid
#
# Everything comes from /proc, so there are no dependencies beyond coreutils.
# Run as root (or as the recorder's own user) to get the disk-write counters;
# without that permission the I/O line is reported as unavailable.

set -uo pipefail

# Associative arrays for the per-thread accounting. The robot is bookworm
# (bash 5); macOS ships bash 3.2, where this would silently mis-report.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Needs bash 4+; this is ${BASH_VERSION}." >&2
    exit 1
fi

DURATION=30
INTERVAL=5
PID=""
OUT=""

# Overridable only so the measurement math can be exercised against a synthetic
# tree in tests; on the robot this is always /proc.
PROC="${PROC_ROOT:-/proc}"

while (( $# )); do
    case "$1" in
        -p|--pid) PID="$2"; shift 2 ;;
        -i|--interval) INTERVAL="$2"; shift 2 ;;
        -o|--out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) DURATION="$1"; shift ;;
    esac
done

# ------------------------------------------------------------------ find it --

if [[ -z "${PID}" ]]; then
    # The recorder is the `ros2 bag record` CLI process; rosbag2 does the work
    # in-process, so this one pid is the whole cost.
    PID="$(pgrep -f 'ros2 bag record' | head -1)"
fi
if [[ -z "${PID}" ]]; then
    PID="$(pgrep -f 'rosbag2.*record' | head -1)"
fi
if [[ -z "${PID}" || ! -d "${PROC}/${PID}" ]]; then
    echo "No running bag recorder found." >&2
    echo "Start one, or pass the pid with -p. Looked for: 'ros2 bag record'." >&2
    exit 1
fi

CMDLINE="$(tr '\0' ' ' < "${PROC}/${PID}/cmdline")"
NCPU="$(nproc)"
HZ="$(getconf CLK_TCK)"

# The -o argument is the bag directory; used for the growth measurement below.
BAGDIR="$(sed -n 's/.*-o \([^ ]*\).*/\1/p' <<<"${CMDLINE}")"

# --------------------------------------------------------------- /proc bits --

# utime+stime in ticks for one /proc/.../stat file. comm can contain spaces and
# parens, so drop everything through the last ') ' before splitting on fields.
cpu_ticks() {
    local line rest
    line="$(cat "$1" 2>/dev/null)" || return 1
    rest="${line##*') '}"
    # rest now starts at field 3 (state), so utime (14) is ${12} and stime (15)
    # is ${13}. Braces are required: $12 would parse as $1 followed by "2".
    # shellcheck disable=SC2086
    set -- ${rest}
    echo $(( ${12} + ${13} ))
}

thread_name() {
    local line
    line="$(cat "$1" 2>/dev/null)" || return 1
    line="${line#*(}"
    echo "${line%%)*}"
}

write_bytes() {
    awk '/^write_bytes:/ {print $2}' "${PROC}/${PID}/io" 2>/dev/null
}

dir_bytes() {
    [[ -n "${BAGDIR}" && -d "${BAGDIR}" ]] || return 1
    du -sb "${BAGDIR}" 2>/dev/null | cut -f1
}

# ------------------------------------------------------------------- output --

# Results land next to the bags, on whatever filesystem the recorder is already
# writing to (from its own -o), then /media, then /data, then the cwd.
if [[ -z "${OUT}" ]]; then
    for d in "${BAGDIR%/*}" /media /data .; do
        if [[ -d "${d}" && -w "${d}" ]]; then
            OUT="${d}/cpu-baseline-$(uname -n)-$(date +%Y%m%d_%H%M%S).txt"
            break
        fi
    done
fi

# ------------------------------------------------------------------- header --

main() {

echo "=============================================================="
echo " rosbag recorder CPU baseline"
echo "=============================================================="
echo " pid          : ${PID}"
echo " cmd          : ${CMDLINE}"
echo " bag dir      : ${BAGDIR:-<not found in cmdline>}"
echo " host         : $(uname -n)  (${NCPU} cores)"
echo " window       : ${DURATION}s, sampled every ${INTERVAL}s"
echo " started      : $(date -Is)"
echo "--------------------------------------------------------------"

# ------------------------------------------------------------------- sample --

t0_cpu="$(cpu_ticks "${PROC}/${PID}/stat")" || { echo "recorder exited" >&2; exit 1; }
t0_wall="$(date +%s.%N)"
t0_write="$(write_bytes)"
t0_size="$(dir_bytes)"

declare -A thread0 threadname
for s in "${PROC}/${PID}"/task/*/stat; do
    tid="${s%/stat}"; tid="${tid##*/}"
    thread0["${tid}"]="$(cpu_ticks "${s}")"
done

# The throttle / jpeg_republisher nodes are spawned by launch_rosbag only when
# record is true, and they receive the FULL-rate stream. Their cost belongs to
# recording even though it lands in another process.
declare -A helper0 helpername
for hpid in $(pgrep -f 'topic_tools|jpeg_republisher|throttle' 2>/dev/null); do
    [[ "${hpid}" == "${PID}" || ! -d "${PROC}/${hpid}" ]] && continue
    helper0["${hpid}"]="$(cpu_ticks "${PROC}/${hpid}/stat")" || continue
    helpername["${hpid}"]="$(tr '\0' ' ' < "${PROC}/${hpid}/cmdline" | cut -c1-70)"
done

echo " interim (cores):"
now_cpu="${t0_cpu}"; now_wall="${t0_wall}"
prev_cpu="${t0_cpu}"; prev_wall="${t0_wall}"
peak=0; trough=999
elapsed=0
while (( elapsed < DURATION )); do
    step=$(( DURATION - elapsed < INTERVAL ? DURATION - elapsed : INTERVAL ))
    sleep "${step}"
    elapsed=$(( elapsed + step ))

    now_cpu="$(cpu_ticks "${PROC}/${PID}/stat")" || { echo " recorder exited after ${elapsed}s" >&2; break; }
    now_wall="$(date +%s.%N)"
    cores="$(awk -v d=$(( now_cpu - prev_cpu )) -v w0="${prev_wall}" -v w1="${now_wall}" -v hz="${HZ}" \
        'BEGIN {printf "%.3f", (d/hz)/(w1-w0)}')"
    printf "   t+%-5ss %6s cores\n" "${elapsed}" "${cores}"
    peak="$(awk -v a="${peak}" -v b="${cores}" 'BEGIN {print (b>a)?b:a}')"
    trough="$(awk -v a="${trough}" -v b="${cores}" 'BEGIN {print (b<a)?b:a}')"
    prev_cpu="${now_cpu}"; prev_wall="${now_wall}"
done

t1_cpu="${now_cpu}"
t1_wall="${now_wall}"

# Snapshot the threads HERE, not down in the reporting section: du and the
# summary awks take long enough that a later read would stretch each thread's
# window past WALL and inflate every per-thread figure.
declare -A thread1
for s in "${PROC}/${PID}"/task/*/stat; do
    tid="${s%/stat}"; tid="${tid##*/}"
    thread1["${tid}"]="$(cpu_ticks "${s}")"
    threadname["${tid}"]="$(thread_name "${s}")"
done

t1_write="$(write_bytes)"
t1_size="$(dir_bytes)"

# ------------------------------------------------------------------ results --

WALL="$(awk -v a="${t0_wall}" -v b="${t1_wall}" 'BEGIN {printf "%.2f", b-a}')"
AVG="$(awk -v d=$(( t1_cpu - t0_cpu )) -v w="${WALL}" -v hz="${HZ}" 'BEGIN {printf "%.3f", (d/hz)/w}')"

echo "--------------------------------------------------------------"
echo " TOTAL over ${WALL}s"
printf "   average   : %s cores  (%.1f%% of one core, %.1f%% of ${NCPU} logical)\n" \
    "${AVG}" \
    "$(awk -v a="${AVG}" 'BEGIN {print a*100}')" \
    "$(awk -v a="${AVG}" -v n="${NCPU}" 'BEGIN {print a*100/n}')"
printf "   min / max : %s / %s cores  (per %ss sample)\n" "${trough}" "${peak}" "${INTERVAL}"

if [[ -n "${t0_write}" && -n "${t1_write}" ]]; then
    awk -v d=$(( t1_write - t0_write )) -v w="${WALL}" \
        'BEGIN {printf "   disk write: %.1f MB total, %.2f MB/s\n", d/1048576, d/1048576/w}'
else
    echo "   disk write: unavailable (need root or the recorder's own uid)"
fi

if [[ -n "${t0_size}" && -n "${t1_size}" ]]; then
    awk -v d=$(( t1_size - t0_size )) -v w="${WALL}" \
        'BEGIN {printf "   bag growth: %.1f MB total, %.2f MB/s (%.1f GB/h)\n", \
                d/1048576, d/1048576/w, d/1073741824*3600/w}'
fi

echo "--------------------------------------------------------------"
echo " per-thread (cores, descending) — threads above 0.005 only"
{
    for tid in "${!thread1[@]}"; do
        # A thread that appeared mid-window has no t0 reading; skip it rather
        # than charge its whole lifetime to this window.
        [[ -n "${thread0[$tid]+set}" ]] || continue
        awk -v d=$(( ${thread1[$tid]} - ${thread0[$tid]} )) -v w="${WALL}" -v hz="${HZ}" \
            -v tid="${tid}" -v n="${threadname[$tid]}" \
            'BEGIN {c=(d/hz)/w; if (c >= 0.005) printf "%.3f %s %s\n", c, tid, n}'
    done
} | sort -rn | awk '{printf "   %6.3f  tid %-8s %s\n", $1, $2, $3}'

echo "--------------------------------------------------------------"
TOTAL="${AVG}"
if (( ${#helper0[@]} )); then
    echo " helper nodes spawned by launch_rosbag (cost of recording too)"
    for hpid in "${!helper0[@]}"; do
        after="$(cpu_ticks "${PROC}/${hpid}/stat")" || continue
        hcores="$(awk -v d=$(( after - ${helper0[$hpid]} )) -v w="${WALL}" -v hz="${HZ}" \
            'BEGIN {printf "%.3f", (d/hz)/w}')"
        printf "   %6s  pid %-8s %s\n" "${hcores}" "${hpid}" "${helpername[$hpid]}"
        TOTAL="$(awk -v a="${TOTAL}" -v b="${hcores}" 'BEGIN {printf "%.3f", a+b}')"
    done
    echo "   ------"
    printf "   %6s  recorder + helpers\n" "${TOTAL}"
    echo "--------------------------------------------------------------"
fi

echo " VP-15657 budgets: debug < 1.00 cores, prod < 0.25 cores"
awk -v a="${TOTAL}" 'BEGIN {
    printf "   measured %.3f cores -> debug %s, prod %s\n", a,
        (a < 1.0  ? "PASS" : "OVER"),
        (a < 0.25 ? "PASS" : "OVER")
}'
echo "=============================================================="

}

{ main; echo " saved: ${OUT}"; } | tee "${OUT}"
