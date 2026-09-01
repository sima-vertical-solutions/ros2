#!/usr/bin/env bash
#
# Attribute recorder CPU to messages vs bytes by ablation (VP-15657).
#
# /proc accounts per thread, not per subscription, so no per-topic CPU number
# exists to read. This gets it indirectly: record several topic subsets, and
# for each one measure cores, message rate and byte rate over the same window.
# Fitting
#
#     cores = alpha * (msgs/s) + beta * (MB/s) + c
#
# gives the per-message and per-byte costs, after which every topic's share is
# computable from its own rate -- no further runs needed.
#
# The subsets below are chosen so the fit is identifiable: some add many
# messages and almost no bytes (IMU, power board, nav), others add many bytes
# at a low message rate (colour, rtabmap). A series that only grew the topic
# list uniformly could not separate the two coefficients.
#
# Run on the robot with the stack up and the normal recorder STOPPED:
#
#     ./rosbag-ablate.sh                 # full series, 60 s per run
#     ./rosbag-ablate.sh -w 30           # shorter window
#     ./rosbag-ablate.sh -o /media/ablate
#
# Needs mcap-topic-breakdown.py beside it (used to count what actually landed).

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Needs bash 4+; this is ${BASH_VERSION}." >&2
    exit 1
fi

WINDOW=60          # measured seconds per run
SETTLE=12          # seconds after start before measuring (discovery + subscribe)
OUTDIR=""
COMPRESS=1
KEEP=0

while (( $# )); do
    case "$1" in
        -w|--window) WINDOW="$2"; shift 2 ;;
        -s|--settle) SETTLE="$2"; shift 2 ;;
        -o|--outdir) OUTDIR="$2"; shift 2 ;;
        --no-compression) COMPRESS=0; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
BREAKDOWN="${HERE}/mcap-topic-breakdown.py"
HZ="$(getconf CLK_TCK)"

for d in "${OUTDIR}" /media/ablate /data/ablate /tmp/ablate; do
    [[ -z "${d}" ]] && continue
    if mkdir -p "${d}" 2>/dev/null && [[ -w "${d}" ]]; then OUTDIR="${d}"; break; fi
done
[[ -z "${OUTDIR}" ]] && { echo "no writable output directory" >&2; exit 1; }

# ----------------------------------------------------------------- subsets --
#
# Cumulative: each run is the previous set plus one group, so a run's marginal
# cost is the difference from the row above it. Order alternates message-heavy
# and byte-heavy groups.

TF="/tf /tf_static /odometry/filtered"
IMU="/sima/sensors/base/imu/imu_raw /sima/sensors/base/imu_filter/filtered/imu"
POWER="/sima/robot/base/power_board_node/twist /sima/robot/base/power_board_node/joint_states
       /sima/robot/base/power_board_node/pb_status /sima/robot/base/power_board_node/pb_info
       /sima/robot/base/power_board_node/battery_state"
NAV="/cmd_vel /cmd_vel_nav /cmd_vel_smoothed /received_global_plan /lookahead_collision_arc
     /lookahead_point /is_rotating_to_heading /local_costmap/published_footprint
     /global_costmap/published_footprint"
COLOR="/sima/sensors/front/camera/color/image_raw /sima/sensors/front/camera/color/camera_info"
RTAB_HEAVY="/rtabmap/odom_rgbd_image /rtabmap/odom_sensor_data/compressed
            /rtabmap/mapData /rtabmap/odom_sensor_data/features"
SEG="/simaai/segmentation/detections /simaai/sensor_fusion/output
     /simaai/sensor_fusion/dynamic_points /simaai/pose/detections"
GCOST="/global_costmap/costmap /local_costmap/costmap"

declare -a NAMES=(
    "01-tf-odom"           # tiny control point
    "02-+imu"              # +200 msg/s, ~0.04 MB/s   <- messages, no bytes
    "03-+powerboard"       # +105 msg/s, ~0.03 MB/s   <- messages, no bytes
    "04-+nav"              # +120 msg/s, ~0.04 MB/s   <- messages, no bytes
    "05-+color"            # +18 msg/s,  ~14  MB/s    <- bytes, no messages
    "06-+rtabmap-heavy"    # +6 msg/s,   ~3.5 MB/s    <- bytes, no messages
    "07-+segmentation"     # +26 msg/s,  ~1.7 MB/s
    "08-+costmaps"         # +2 msg/s,   ~2.9 MB/s    <- bytes, no messages
)
declare -a SETS=(
    "${TF}"
    "${TF} ${IMU}"
    "${TF} ${IMU} ${POWER}"
    "${TF} ${IMU} ${POWER} ${NAV}"
    "${TF} ${IMU} ${POWER} ${NAV} ${COLOR}"
    "${TF} ${IMU} ${POWER} ${NAV} ${COLOR} ${RTAB_HEAVY}"
    "${TF} ${IMU} ${POWER} ${NAV} ${COLOR} ${RTAB_HEAVY} ${SEG}"
    "${TF} ${IMU} ${POWER} ${NAV} ${COLOR} ${RTAB_HEAVY} ${SEG} ${GCOST}"
)

# ------------------------------------------------------------------- utils --

cpu_ticks() {
    local line rest
    line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${line##*') '}"
    # shellcheck disable=SC2086
    set -- ${rest}
    echo $(( ${12} + ${13} ))
}

RESULTS="${OUTDIR}/ablate-results.tsv"
: > "${RESULTS}"

printf "%-20s %7s %9s %9s %9s\n" "run" "cores" "msgs/s" "MB/s" "topics"
printf -- "-%.0s" {1..60}; echo

for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    # shellcheck disable=SC2206
    topics=(${SETS[$i]})
    bag="${OUTDIR}/${name}"
    rm -rf "${bag}"

    cmd=(ros2 bag record -o "${bag}")
    (( COMPRESS )) && cmd+=(--storage-preset-profile zstd_fast)
    cmd+=("${topics[@]}")

    "${cmd[@]}" >/dev/null 2>&1 &
    rec=$!
    sleep "${SETTLE}"

    if ! kill -0 "${rec}" 2>/dev/null; then
        echo "${name}: recorder exited during settle -- skipped" >&2
        continue
    fi

    t0="$(cpu_ticks "${rec}")"; w0="$(date +%s.%N)"
    sleep "${WINDOW}"
    t1="$(cpu_ticks "${rec}")"; w1="$(date +%s.%N)"

    # SIGINT so rosbag2 writes the mcap summary; without it the file has no index.
    kill -INT "${rec}" 2>/dev/null
    wait "${rec}" 2>/dev/null

    cores="$(awk -v d=$(( t1 - t0 )) -v a="${w0}" -v b="${w1}" -v hz="${HZ}" \
        'BEGIN {printf "%.3f", (d/hz)/(b-a)}')"

    mcap="$(find "${bag}" -name '*.mcap' -print -quit 2>/dev/null)"
    msgs=0; mbps=0
    if [[ -n "${mcap}" && -x "${BREAKDOWN}" ]]; then
        # Field positions verified against the breakdown's header:
        #   duration   : 584.4 s (9.7 min)              -> $3
        #   uncompressed payload : 8.39 GB (14.70 MB/s) -> $4, in GB
        #   topics     : 63,  messages: 371,082 (635/s) -> $5, comma-grouped
        read -r msgs mbps < <(python3 "${BREAKDOWN}" "${mcap}" 2>/dev/null | awk '
            /^duration/            {dur=$3}
            /uncompressed payload/ {mb=$4*1024}
            /^topics/              {gsub(/,/,"",$5); n=$5}
            END {if (dur>0) printf "%.1f %.2f", n/dur, mb/dur; else print "0 0"}')
    fi

    printf "%-20s %7s %9s %9s %9d\n" "${name}" "${cores}" "${msgs}" "${mbps}" "${#topics[@]}"
    printf "%s\t%s\t%s\t%s\t%d\n" "${name}" "${cores}" "${msgs}" "${mbps}" "${#topics[@]}" >> "${RESULTS}"

    (( KEEP )) || rm -rf "${bag}"
done

# --------------------------------------------------------------------- fit --

echo
python3 - "${RESULTS}" <<'PY'
import sys

rows = []
for line in open(sys.argv[1]):
    p = line.split("\t")
    if len(p) >= 4:
        try:
            rows.append((float(p[1]), float(p[2]), float(p[3])))
        except ValueError:
            pass

if len(rows) < 4:
    sys.exit("Not enough runs to fit (need 4+).")

# Least squares for cores = a*msgs + b*mb + c, via the 3x3 normal equations.
n = len(rows)
X = [[m, mb, 1.0] for _c, m, mb in rows]
y = [c for c, _m, _mb in rows]
A = [[sum(X[k][i] * X[k][j] for k in range(n)) for j in range(3)] + \
     [sum(X[k][i] * y[k] for k in range(n))] for i in range(3)]

for i in range(3):                                  # Gaussian elimination
    p = max(range(i, 3), key=lambda r: abs(A[r][i]))
    A[i], A[p] = A[p], A[i]
    if abs(A[i][i]) < 1e-12:
        sys.exit("Design is singular -- the subsets did not separate messages from bytes.")
    for r in range(3):
        if r != i:
            f = A[r][i] / A[i][i]
            for cix in range(i, 4):
                A[r][cix] -= f * A[i][cix]
a, b, c = (A[i][3] / A[i][i] for i in range(3))

pred = [a * m + b * mb + c for _c, m, mb in rows]
ss_res = sum((y[k] - pred[k]) ** 2 for k in range(n))
ybar = sum(y) / n
ss_tot = sum((v - ybar) ** 2 for v in y) or 1e-12

print("fit: cores = a*(msgs/s) + b*(MB/s) + c")
print(f"  a = {a * 1e6:8.2f} microcores per msg/s   ({a * 1000:.4f} millicores per msg/s)")
print(f"  b = {b * 1000:8.2f} millicores per MB/s")
print(f"  c = {c:8.3f} cores fixed overhead")
print(f"  R^2 = {1 - ss_res / ss_tot:.4f} over {n} runs")
print()
# At the full-bag operating point measured earlier: 635 msg/s, 14.70 MB/s.
mp, bp = a * 635, b * 14.70
tot = mp + bp + c
if tot > 0:
    print(f"at 635 msg/s and 14.70 MB/s -> {tot:.3f} cores: "
          f"{100 * mp / tot:.0f}% per-message, {100 * bp / tot:.0f}% per-byte, "
          f"{100 * c / tot:.0f}% fixed")
    print("Per-topic cost is now a*hz + b*mbps for any topic in the breakdown table.")
PY

echo
echo "raw results: ${RESULTS}"
