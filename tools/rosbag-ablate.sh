#!/usr/bin/env bash
#
# Price each topic group by leave-one-out ablation (VP-15657).
#
# /proc accounts per thread, not per subscription, so there is no per-topic CPU
# number to read. This measures it: record the full list, then record the full
# list minus one group at a time. Each group's marginal cost is the difference.
#
# Leave-one-out rather than build-up, deliberately. A cumulative series prices
# the IMU at 275 msg/s with five subscriptions; you care what it costs at full
# load with eighty, where cache locality is worse and the executor's waitset
# scan is longer. Measuring each group's marginal cost AT the operating point
# you actually run at also needs no linearity assumption -- the answer is a
# subtraction, not a fitted model.
#
# It doubles as a saturation test. If removing group X raises the landed rate of
# topics in OTHER groups, the recorder was dropping messages before -- which
# invalidates any CPU comparison across configurations, since the cheaper-
# looking run was simply doing less work than it was asked to.
#
#     ./rosbag-ablate.sh -c vista_v1_config.yaml               # full series, 60 s/run
#     ./rosbag-ablate.sh -c vista_v1_config.yaml --repeat-control
#     ./rosbag-ablate.sh --topics-from 1234                    # or lift from a live recorder
#
# Stop the normal recorder first -- this starts its own. Taking the topic list
# from the config rather than from a running recorder means nothing has to be
# running when you start.
# Needs mcap-topic-breakdown.py beside it.

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Needs bash 4+; this is ${BASH_VERSION}." >&2; exit 1
fi

WINDOW=60
SETTLE=12
OUTDIR=""
FROMPID=""
TOPICSFILE=""
CONFIG=""
COMPRESS=1
RECONTROL=0

while (( $# )); do
    case "$1" in
        -w|--window) WINDOW="$2"; shift 2 ;;
        -s|--settle) SETTLE="$2"; shift 2 ;;
        -o|--outdir) OUTDIR="$2"; shift 2 ;;
        -c|--config) CONFIG="$2"; shift 2 ;;
        --topics-from) FROMPID="$2"; shift 2 ;;
        --topics-file) TOPICSFILE="$2"; shift 2 ;;
        --no-compression) COMPRESS=0; shift ;;
        --repeat-control) RECONTROL=1; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
BREAKDOWN="${HERE}/mcap-topic-breakdown.py"
HZ="$(getconf CLK_TCK)"
[[ -r "${BREAKDOWN}" ]] || { echo "mcap-topic-breakdown.py not found beside this script." >&2; exit 1; }

for d in "${OUTDIR}" /media/ablate /data/ablate /tmp/ablate; do
    [[ -z "${d}" ]] && continue
    mkdir -p "${d}" 2>/dev/null && [[ -w "${d}" ]] && { OUTDIR="${d}"; break; }
done
[[ -z "${OUTDIR}" ]] && { echo "no writable output directory" >&2; exit 1; }

# ------------------------------------------------------------- the groups --
#
# Each group is removed in turn. Grouped by what you would actually decide to
# drop together, not by namespace: the question is "what does cutting this cost
# me and save me", and that decision is made per capability.

declare -A GROUP=(
  [imu-raw]="/sima/sensors/base/imu/imu_raw"
  [imu-filtered]="/sima/sensors/base/imu_filter/filtered/imu"
  [pb-twist]="/sima/robot/base/power_board_node/twist"
  [tf]="/tf"
  [nav-debug]="/received_global_plan /lookahead_collision_arc /lookahead_point /is_rotating_to_heading"
  [color-raw]="/sima/sensors/front/camera/color/image_raw"
  [rtabmap-heavy]="/rtabmap/odom_rgbd_image /rtabmap/odom_sensor_data/compressed /rtabmap/mapData /rtabmap/odom_sensor_data/features"
  [segmentation]="/simaai/segmentation/detections"
  [global-costmap]="/global_costmap/costmap"
  [coverage]="/coverage/map /coverage/swath_path /coverage/swath_debug_markers"
)
ORDER=(imu-raw imu-filtered pb-twist tf nav-debug color-raw rtabmap-heavy segmentation global-costmap coverage)

# --------------------------------------------------------- the full list --

# Read the rosbag.topics allowlist out of a system config yaml. Verified to
# reproduce the deployed recorder's list exactly from vista_v1_config.yaml.
# Hand-rolled rather than via a yaml module so this stays dependency-free.
topics_from_config() {
    awk '
      /^[a-zA-Z_]/ { inrb = ($0 ~ /^rosbag:/); intopics = 0 }
      inrb && /^[[:space:]]+topics:[[:space:]]*$/ { intopics = 1; next }
      inrb && intopics && /^[[:space:]]+[a-zA-Z_]+:/ { intopics = 0 }
      inrb && intopics && /^[[:space:]]*-[[:space:]]+\// {
          sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+#.*$/, ""); sub(/[[:space:]]+$/, "")
          print
      }' "$1"
}

declare -a FULL=()
if [[ -n "${TOPICSFILE}" ]]; then
    mapfile -t FULL < <(grep -v '^[[:space:]]*$' "${TOPICSFILE}")
elif [[ -n "${CONFIG}" ]]; then
    [[ -r "${CONFIG}" ]] || { echo "cannot read ${CONFIG}" >&2; exit 1; }
    mapfile -t FULL < <(topics_from_config "${CONFIG}")
    echo "Read ${#FULL[@]} topics from $(basename "${CONFIG}")."
else
    src="${FROMPID:-$(pgrep -f 'ros2 bag record' | head -1)}"
    [[ -z "${src}" || ! -r "/proc/${src}/cmdline" ]] && {
        echo "No topic list. Pass --config vista_v1_config.yaml (easiest)," >&2
        echo "or --topics-file FILE, or --topics-from PID." >&2
        exit 1; }
    mapfile -t FULL < <(tr '\0' '\n' < "/proc/${src}/cmdline" | grep '^/')
    echo "Lifted ${#FULL[@]} topics from pid ${src}. Stop that recorder before trusting results."
fi
if (( ${#FULL[@]} < 5 )); then
    echo "Only ${#FULL[@]} topics found." >&2
    [[ -n "${CONFIG}" ]] && echo "That config has no rosbag.topics allowlist -- configs like
isaac_hil.yaml record with '-a' plus exclude_topics instead, which has no
explicit list to ablate. Use a config with a topics: block, or --topics-file." >&2
    exit 1
fi

# ------------------------------------------------------------------ utils --

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

# measure NAME topic... -> appends a row, echoes "cores msgs mb"
measure() {
    local tag="$1"; shift
    local bag="${OUTDIR}/${tag}"
    rm -rf "${bag}"

    local cmd=(ros2 bag record -o "${bag}")
    (( COMPRESS )) && cmd+=(--storage-preset-profile zstd_fast)
    cmd+=("$@")

    "${cmd[@]}" >/dev/null 2>&1 &
    local rec=$!
    sleep "${SETTLE}"
    kill -0 "${rec}" 2>/dev/null || { echo "0 0 0"; return; }

    local t0 w0 t1 w1
    t0="$(cpu_ticks "${rec}")"; w0="$(date +%s.%N)"
    sleep "${WINDOW}"
    t1="$(cpu_ticks "${rec}")"; w1="$(date +%s.%N)"
    kill -INT "${rec}" 2>/dev/null; wait "${rec}" 2>/dev/null

    local cores mcap rates="0 0"
    cores="$(awk -v d=$(( t1 - t0 )) -v a="${w0}" -v b="${w1}" -v hz="${HZ}" \
        'BEGIN {printf "%.3f", (d/hz)/(b-a)}')"
    mcap="$(find "${bag}" -name '*.mcap' -print -quit 2>/dev/null)"
    if [[ -n "${mcap}" ]]; then
        # Per-topic CSV is kept: the saturation check compares rates across runs.
        python3 "${BREAKDOWN}" "${mcap}" --csv "${OUTDIR}/${tag}.csv" >"${OUTDIR}/${tag}.txt" 2>/dev/null
        rates="$(awk '
            /^duration/            {dur=$3}
            /uncompressed payload/ {mb=$4*1024}
            /^topics/              {gsub(/,/,"",$5); n=$5}
            END {if (dur>0) printf "%.1f %.2f", n/dur, mb/dur; else print "0 0"}' "${OUTDIR}/${tag}.txt")"
    fi
    rm -rf "${bag}"
    printf "%s\t%s\t%s\n" "${tag}" "${cores}" "${rates// /$'\t'}" >> "${RESULTS}"
    echo "${cores} ${rates}"
}

# -------------------------------------------------------------------- run --

echo "=============================================================="
echo " leave-one-out ablation -- ${#FULL[@]} topics, ${#ORDER[@]} groups"
echo " ${WINDOW}s per run, $(( (${#ORDER[@]} + 1 + RECONTROL) * (WINDOW + SETTLE) / 60 )) min total"
echo "=============================================================="
printf "%-18s %8s %10s %9s\n" "run" "cores" "msgs/s" "MB/s"
printf -- "-%.0s" {1..50}; echo

read -r FC FM FB < <(measure "full" "${FULL[@]}")
printf "%-18s %8s %10s %9s   <- control\n" "full" "${FC}" "${FM}" "${FB}"

for g in "${ORDER[@]}"; do
    # shellcheck disable=SC2206
    cut=(${GROUP[$g]})
    declare -a sub=()
    for t in "${FULL[@]}"; do
        skip=0
        for c in "${cut[@]}"; do [[ "${t}" == "${c}" ]] && { skip=1; break; }; done
        (( skip )) || sub+=("${t}")
    done
    if (( ${#sub[@]} == ${#FULL[@]} )); then
        echo "  (skipped ${g}: none of its topics are in the list)"
        continue
    fi
    read -r c m b < <(measure "no-${g}" "${sub[@]}")
    printf "%-18s %8s %10s %9s\n" "no-${g}" "${c}" "${m}" "${b}"
    unset sub
done

# A second control at the end: if it disagrees with the first, the robot's own
# workload drifted during the series and every marginal number is suspect.
if (( RECONTROL )); then
    read -r F2C F2M F2B < <(measure "full2" "${FULL[@]}")
    printf "%-18s %8s %10s %9s   <- control repeat\n" "full2" "${F2C}" "${F2M}" "${F2B}"
fi

# ---------------------------------------------------------------- report --

echo
python3 - "${RESULTS}" "${OUTDIR}" <<'PY'
import sys, os, csv

res, outdir = sys.argv[1], sys.argv[2]
rows = {}
order = []
for line in open(res):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4:
        try:
            rows[p[0]] = (float(p[1]), float(p[2]), float(p[3]))
        except ValueError:
            continue
        order.append(p[0])

if "full" not in rows:
    sys.exit("The control run produced no data.")
fc, fm, fb = rows["full"]

print("=" * 74)
print(" marginal cost of each group, measured at full load")
print("=" * 74)
print(f" control: {fc:.3f} cores at {fm:.1f} msg/s, {fb:.2f} MB/s")
if "full2" in rows:
    f2 = rows["full2"][0]
    drift = abs(f2 - fc)
    flag = "  <-- LARGE, treat everything below as indicative only" if drift > 0.1 else ""
    print(f" control repeat: {f2:.3f} cores (drift {drift:.3f}){flag}")
print()
print(f" {'group removed':<18}{'Δcores':>9}{'Δmsgs/s':>10}{'ΔMB/s':>9}{'cores/1k msg':>14}{'cores/MB/s':>12}")
print(" " + "-" * 71)

marg = []
for name in order:
    if not name.startswith("no-"):
        continue
    c, m, b = rows[name]
    if m <= 0:
        continue
    dc, dm, db = fc - c, fm - m, fb - b
    per_msg = (dc / dm * 1000) if dm > 1 else float("nan")
    per_mb = (dc / db) if db > 0.05 else float("nan")
    marg.append((name[3:], dc, dm, db, per_msg, per_mb))
    f = lambda v, w, p: (f"{v:>{w}.{p}f}" if v == v else " " * (w - 3) + "n/a")
    print(f" {name[3:]:<18}{dc:>9.3f}{dm:>10.1f}{db:>9.2f}{f(per_msg,14,4)}{f(per_mb,12,4)}")

print()
tot = sum(m[1] for m in marg)
print(f" groups sum to {tot:.3f} cores of the {fc:.3f} measured "
      f"({100*tot/fc:.0f}%). The remainder is fixed overhead plus")
print(" the topics no group covers -- marginal costs do not have to add up, and a")
print(" large gap means the cost is mostly per-subscription rather than per-message.")

# ---- saturation check -------------------------------------------------
print()
print("=" * 74)
print(" saturation check -- did removing a group let OTHER topics land faster?")
print("=" * 74)

def load(tag):
    p = os.path.join(outdir, f"{tag}.csv")
    if not os.path.exists(p):
        return {}
    return {r["topic"]: float(r["hz"]) for r in csv.DictReader(open(p))}

base = load("full")
found = False
if base:
    for name in order:
        if not name.startswith("no-"):
            continue
        sub = load(name)
        risen = []
        for topic, hz in sub.items():
            b = base.get(topic, 0)
            if b > 1.0 and hz > b * 1.10:
                risen.append((topic, b, hz))
        if risen:
            found = True
            risen.sort(key=lambda r: -(r[2] / r[1]))
            print(f"\n removing {name[3:]} raised {len(risen)} other topic(s):")
            for topic, b, hz in risen[:6]:
                print(f"   {topic:<52} {b:6.1f} -> {hz:6.1f} Hz  (+{100*(hz/b-1):.0f}%)")

if not found:
    print(" No topic's rate rose materially when others were removed.")
    print(" The recorder is keeping up, so the CPU numbers above are comparable.")
else:
    print()
    print(" The recorder was SHEDDING LOAD in the control run. Runs that look cheaper")
    print(" may simply have dropped less, so marginal costs are understated. Re-run")
    print(" with a shorter topic list as the control, or fix the drops first.")
print("=" * 74)
PY

echo
echo "raw results  : ${RESULTS}"
echo "per-run CSVs : ${OUTDIR}/*.csv"
