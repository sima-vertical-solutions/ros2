#!/usr/bin/env bash
#
# Profile the running bag recorder to see WHERE its cycles go (VP-15657).
#
# The CPU baseline says how much; this says what. It answers the question the
# thread split can only hint at: is the cost DDS transport, the RMW/serialised
# take path, rosbag2's own bookkeeping, mcap chunking, zstd, or the kernel.
#
# Attribution is by shared object, not call graph. That is deliberate: ROS 2
# binaries on arm64 are built without frame pointers, so stack unwinding needs
# DWARF, which is heavy enough at 99 Hz to perturb the very thing being
# measured. A flat profile bucketed by DSO answers "which subsystem" exactly,
# costs almost nothing, and needs no debug info. Pass --graph if you later want
# call chains for a specific hot symbol.
#
#     ./rosbag-perf.sh                # 30 s on the running recorder
#     ./rosbag-perf.sh 60             # longer sample
#     ./rosbag-perf.sh -p 1234 --graph
#
# Needs linux-perf and perf_event_paranoid <= 1 (or root). Both are checked.

set -uo pipefail

DURATION=30
FREQ=99
PID=""
GRAPH=0
OUT=""

while (( $# )); do
    case "$1" in
        -p|--pid) PID="$2"; shift 2 ;;
        -F|--freq) FREQ="$2"; shift 2 ;;
        -o|--out) OUT="$2"; shift 2 ;;
        --graph) GRAPH=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) DURATION="$1"; shift ;;
    esac
done

# ------------------------------------------------------------- preflight --

if ! command -v perf >/dev/null 2>&1; then
    echo "perf is not installed." >&2
    echo "  apt-get install linux-perf     (then re-run)" >&2
    echo "Without it, run rosbag-falsify.sh instead -- it needs no tooling." >&2
    exit 1
fi

PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)"
if (( PARANOID > 1 && EUID != 0 )); then
    echo "perf_event_paranoid is ${PARANOID}; need <= 1 or root." >&2
    echo "  sudo sysctl -w kernel.perf_event_paranoid=1" >&2
    exit 1
fi

if [[ -z "${PID}" ]]; then
    PID="$(pgrep -f 'ros2 bag record' | head -1)"
fi
if [[ -z "${PID}" || ! -d "/proc/${PID}" ]]; then
    echo "No running bag recorder found. Start one, or pass -p." >&2
    exit 1
fi

for d in "${OUT}" /media /data /tmp; do
    [[ -n "${d}" && -d "${d}" && -w "${d}" ]] && { OUT="${d}"; break; }
done
STAMP="$(date +%Y%m%d_%H%M%S)"
DATA="${OUT}/perf-recorder-${STAMP}.data"
REPORT="${OUT}/perf-recorder-${STAMP}.txt"

# ---------------------------------------------------------------- record --

echo "profiling pid ${PID} for ${DURATION}s at ${FREQ} Hz..."
rec=(perf record -F "${FREQ}" -p "${PID}" -o "${DATA}")
(( GRAPH )) && rec+=(-g --call-graph fp)
"${rec[@]}" -- sleep "${DURATION}" 2>/dev/null

if [[ ! -s "${DATA}" ]]; then
    echo "perf produced no samples -- is the recorder actually busy?" >&2
    exit 1
fi

# ---------------------------------------------------------------- report --

{
echo "=============================================================="
echo " recorder profile -- where the cycles go"
echo "=============================================================="
echo " pid       : ${PID}"
echo " cmd       : $(tr '\0' ' ' < "/proc/${PID}/cmdline" | cut -c1-160)"
echo " sample    : ${DURATION}s at ${FREQ} Hz"
echo " host      : $(uname -n)"
echo "--------------------------------------------------------------"
echo

# Bucket the flat per-DSO profile into subsystems. The DSO name is the honest
# boundary here: one library, one job.
perf report --stdio --no-children --sort dso -i "${DATA}" 2>/dev/null \
| awk '
/^[[:space:]]*[0-9]+\.[0-9]+%/ {
    pct = $1; sub(/%/, "", pct)
    dso = $2
    for (i = 3; i <= NF; i++) dso = dso " " $i

    l = tolower(dso)
    # Order matters. librmw_fastrtps_cpp.so contains "fastrtps", so the RMW test
    # has to come first or the take/serialise path gets folded into transport --
    # which is precisely the distinction this profile exists to make. Likewise
    # CDR encoding is its own cost, not transport.
    if      (l ~ /rmw/)                                                b = "RMW binding (take/serialise)"
    else if (l ~ /fastcdr|libcdr/)                                     b = "CDR serialisation"
    else if (l ~ /fastrtps|fastdds|foonathan|iceoryx|cyclonedds|ddsc/) b = "DDS transport"
    else if (l ~ /rosbag2_storage_mcap|mcap/)                          b = "MCAP writer"
    else if (l ~ /zstd|lz4/)                                                  b = "Compression (zstd)"
    else if (l ~ /rosbag2/)                                                   b = "rosbag2 core"
    else if (l ~ /rclcpp|librcl|rcutils|rcpputils|rosidl|tracetools/)         b = "ROS client library"
    else if (l ~ /kernel\.kallsyms|\[kernel\]|vmlinux/)                       b = "Kernel (syscall/sched/IO)"
    else if (l ~ /libc|ld-linux|libstdc|libm\.so|libgcc/)                     b = "libc / C++ runtime"
    else if (l ~ /python/)                                                    b = "Python CLI wrapper"
    else                                                                      b = "Other"

    tot[b] += pct; grand += pct
    if (pct > best[b]) { best[b] = pct; top[b] = dso }
}
END {
    # Emit unsorted and let sort(1) order it: asorti is a gawk extension and
    # Debian ships mawk, where it is a runtime error.
    for (b in tot) printf "%.2f\t%s\t%s\n", tot[b], b, top[b]
    printf "%.2f\t~TOTAL\t\n", grand
}' \
| sort -rn \
| {
    printf " %-30s %8s   %s\n" "SUBSYSTEM" "CPU" "largest object"
    printf " %-30s %8s   %s\n" "------------------------------" "-------" "--------------------------"
    total=""
    while IFS=$'\t' read -r pct bucket dso; do
        if [[ "${bucket}" == "~TOTAL" ]]; then total="${pct}"; continue; fi
        printf " %-30s %7s%%   %s\n" "${bucket}" "${pct}" "${dso}"
    done
    [[ -n "${total}" ]] && printf "\n %-30s %7s%%\n" "accounted for" "${total}"
  }

echo
echo "--------------------------------------------------------------"
echo " hottest symbols"
echo "--------------------------------------------------------------"
perf report --stdio --no-children --sort symbol -i "${DATA}" 2>/dev/null \
    | grep -E '^[[:space:]]*[0-9]+\.[0-9]+%' | head -25

echo
echo "--------------------------------------------------------------"
echo " per-thread (matches the tids from rosbag-cpu-baseline.sh)"
echo "--------------------------------------------------------------"
perf report --stdio --no-children --sort tid,dso -i "${DATA}" 2>/dev/null \
    | grep -E '^[[:space:]]*[0-9]+\.[0-9]+%' | head -30

echo
echo "--------------------------------------------------------------"
echo " How to read this"
echo "--------------------------------------------------------------"
cat <<'NOTE'
 DDS transport high      -> the cost is moving messages between processes.
                            Recording fewer/smaller topics helps; so would
                            colocating the recorder with the publisher.
 RMW binding + ROS client
 library high            -> per-message overhead in take//serialise. This is
                            the message-COUNT regime: decimate high-rate
                            topics, the byte-heavy ones barely matter.
 rosbag2 core high       -> queueing and bookkeeping per message. Same fix as
                            above, plus max-cache-size tuning.
 MCAP writer high        -> chunk assembly and CRC. Try noChunkCRC and a
                            larger chunkSize; both are storage-config only.
 Compression high        -> zstd. On a 1.5 GB/s NVMe this buys capacity, not
                            throughput: set compression:false and re-measure.
 Kernel high             -> syscalls and page-cache work. Check whether the
                            fork's FadviseWriter is doing more fadvise calls
                            than it needs to.
NOTE
} | tee "${REPORT}"

echo
echo "raw profile : ${DATA}"
echo "report      : ${REPORT}"
echo "drill down  : perf report -i ${DATA}"
