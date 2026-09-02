#!/usr/bin/env bash
#
# Test the per-message hypothesis in two runs (VP-15657).
#
# The thread split says recorder cost is dominated by per-message work, not by
# bytes. That is an inference, and it is load-bearing for the whole profile
# design -- so falsify it before spending ten minutes on an ablation series.
#
# Run A records the full topic list. Run B records the same list minus the four
# highest-rate topics, which together are ~57% of all messages but only ~4% of
# the bytes. If cost is per-message, B should land near half of A. If B barely
# moves, the per-message reading is wrong and the ablation design needs
# rethinking before it is worth running.
#
# Runs alternate A/B/A/B so a drift in what the robot is doing shows up as
# disagreement between repeats rather than as a fake effect.
#
#     ./rosbag-falsify.sh -c vista_v1_config.yaml       # 2 repeats, 45 s/run (~4 min)
#     ./rosbag-falsify.sh -c vista_v1_config.yaml -w 60 -r 3
#     ./rosbag-falsify.sh --topics-from 1234            # or lift from a live recorder
#
# Stop the normal recorder first -- this starts its own. Taking the topic list
# from the config rather than from a running recorder means nothing has to be
# running when you start.

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Needs bash 4+; this is ${BASH_VERSION}." >&2; exit 1
fi

WINDOW=45
SETTLE=10
REPEATS=2
OUTDIR=""
FROMPID=""
TOPICSFILE=""
CONFIG=""

while (( $# )); do
    case "$1" in
        -w|--window) WINDOW="$2"; shift 2 ;;
        -r|--repeats) REPEATS="$2"; shift 2 ;;
        -s|--settle) SETTLE="$2"; shift 2 ;;
        -o|--outdir) OUTDIR="$2"; shift 2 ;;
        -c|--config) CONFIG="$2"; shift 2 ;;
        --topics-from) FROMPID="$2"; shift 2 ;;
        --topics-file) TOPICSFILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
BREAKDOWN="${HERE}/mcap-topic-breakdown.py"
HZ="$(getconf CLK_TCK)"

# The four topics carrying ~57% of messages and ~4% of bytes, per the bag audit.
CUT=(
    /sima/sensors/base/imu/imu_raw
    /sima/sensors/base/imu_filter/filtered/imu
    /sima/robot/base/power_board_node/twist
    /tf
)

# ------------------------------------------------------- the topic list --

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
    # Lift the list from a recorder's own command line so it always matches what
    # is actually deployed, rather than a copy that drifts out of date.
    src="${FROMPID:-$(pgrep -f 'ros2 bag record' | head -1)}"
    if [[ -z "${src}" || ! -r "/proc/${src}/cmdline" ]]; then
        echo "No topic list. Pass --config vista_v1_config.yaml (easiest)," >&2
        echo "or --topics-file FILE, or --topics-from PID." >&2
        exit 1
    fi
    mapfile -t FULL < <(tr '\0' '\n' < "/proc/${src}/cmdline" | grep '^/')
    echo "Lifted ${#FULL[@]} topics from pid ${src}."
    echo "NOTE: that recorder is still running. Stop it before trusting these numbers,"
    echo "      or the two recorders will compete for the same messages."
    echo
fi

if (( ${#FULL[@]} < 5 )); then
    echo "Only ${#FULL[@]} topics found." >&2
    [[ -n "${CONFIG}" ]] && echo "That config has no rosbag.topics allowlist -- configs like
isaac_hil.yaml record with '-a' plus exclude_topics instead, which has no
explicit list to ablate. Use a config with a topics: block, or --topics-file." >&2
    exit 1
fi

# Set B = full minus CUT
declare -a REDUCED=()
for t in "${FULL[@]}"; do
    skip=0
    for c in "${CUT[@]}"; do [[ "${t}" == "${c}" ]] && { skip=1; break; }; done
    (( skip )) || REDUCED+=("${t}")
done
removed=$(( ${#FULL[@]} - ${#REDUCED[@]} ))
(( removed == 0 )) && { echo "None of the four high-rate topics are in the list." >&2; exit 1; }

for d in "${OUTDIR}" /media/falsify /data/falsify /tmp/falsify; do
    [[ -z "${d}" ]] && continue
    mkdir -p "${d}" 2>/dev/null && [[ -w "${d}" ]] && { OUTDIR="${d}"; break; }
done

# ----------------------------------------------------------------- utils --

cpu_ticks() {
    local line rest
    line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${line##*') '}"
    # shellcheck disable=SC2086
    set -- ${rest}
    echo $(( ${12} + ${13} ))
}

# one run -> "cores msgs_per_s mb_per_s"
measure() {
    local tag="$1"; shift
    local bag="${OUTDIR}/${tag}"
    rm -rf "${bag}"

    ros2 bag record -o "${bag}" --storage-preset-profile zstd_fast "$@" >/dev/null 2>&1 &
    local rec=$!
    sleep "${SETTLE}"
    kill -0 "${rec}" 2>/dev/null || { echo "0 0 0"; return; }

    local t0 w0 t1 w1
    t0="$(cpu_ticks "${rec}")"; w0="$(date +%s.%N)"
    sleep "${WINDOW}"
    t1="$(cpu_ticks "${rec}")"; w1="$(date +%s.%N)"

    kill -INT "${rec}" 2>/dev/null; wait "${rec}" 2>/dev/null

    local cores mcap
    cores="$(awk -v d=$(( t1 - t0 )) -v a="${w0}" -v b="${w1}" -v hz="${HZ}" \
        'BEGIN {printf "%.3f", (d/hz)/(b-a)}')"
    mcap="$(find "${bag}" -name '*.mcap' -print -quit 2>/dev/null)"
    local rates="0 0"
    if [[ -n "${mcap}" ]]; then
        rates="$(python3 "${BREAKDOWN}" "${mcap}" 2>/dev/null | awk '
            /^duration/            {dur=$3}
            /uncompressed payload/ {mb=$4*1024}
            /^topics/              {gsub(/,/,"",$5); n=$5}
            END {if (dur>0) printf "%.1f %.2f", n/dur, mb/dur; else print "0 0"}')"
    fi
    rm -rf "${bag}"
    echo "${cores} ${rates}"
}

# ------------------------------------------------------------------ run --

echo "=============================================================="
echo " per-message hypothesis test"
echo "=============================================================="
echo " A = full list          : ${#FULL[@]} topics"
echo " B = A minus ${removed} topics : ${#REDUCED[@]} topics"
for c in "${CUT[@]}"; do echo "     removed: ${c}"; done
echo " ${REPEATS} repeats, ${WINDOW}s each, alternating A/B"
echo "--------------------------------------------------------------"
printf "%-8s %8s %10s %9s\n" "run" "cores" "msgs/s" "MB/s"

declare -a AC=() BC=() AM=() BM=() AB=() BB=()
for ((i = 1; i <= REPEATS; i++)); do
    read -r c m b < <(measure "A${i}" "${FULL[@]}")
    AC+=("${c}"); AM+=("${m}"); AB+=("${b}")
    printf "%-8s %8s %10s %9s\n" "A${i}" "${c}" "${m}" "${b}"

    read -r c m b < <(measure "B${i}" "${REDUCED[@]}")
    BC+=("${c}"); BM+=("${m}"); BB+=("${b}")
    printf "%-8s %8s %10s %9s\n" "B${i}" "${c}" "${m}" "${b}"
done

# --------------------------------------------------------------- verdict --

echo "--------------------------------------------------------------"
printf '%s\n' "${AC[@]}" > "${OUTDIR}/.ac"; printf '%s\n' "${BC[@]}" > "${OUTDIR}/.bc"
printf '%s\n' "${AM[@]}" > "${OUTDIR}/.am"; printf '%s\n' "${BM[@]}" > "${OUTDIR}/.bm"
printf '%s\n' "${AB[@]}" > "${OUTDIR}/.ab"; printf '%s\n' "${BB[@]}" > "${OUTDIR}/.bb"

python3 - "${OUTDIR}" <<'PY'
import sys, statistics as st
d = sys.argv[1]
rd = lambda n: [float(x) for x in open(f"{d}/.{n}") if x.strip()]
ac, bc, am, bm, ab, bb = (rd(n) for n in ("ac", "bc", "am", "bm", "ab", "bb"))
if not ac or not bc or min(am) <= 0:
    sys.exit("Runs produced no usable data.")

mA, mB = st.mean(ac), st.mean(bc)
msgA, msgB = st.mean(am), st.mean(bm)
mbA, mbB = st.mean(ab), st.mean(bb)

print(f" A: {mA:.3f} cores   {msgA:7.1f} msg/s   {mbA:6.2f} MB/s")
print(f" B: {mB:.3f} cores   {msgB:7.1f} msg/s   {mbB:6.2f} MB/s")
if len(ac) > 1:
    print(f"    repeat spread: A +/-{(max(ac)-min(ac))/2:.3f}, B +/-{(max(bc)-min(bc))/2:.3f} cores")
print()

d_msg = 100 * (1 - msgB / msgA)
d_mb = 100 * (1 - mbB / mbA) if mbA else 0
d_cpu = 100 * (1 - mB / mA)
print(f" removing those topics cut {d_msg:.0f}% of messages and {d_mb:.0f}% of bytes,")
print(f" and cut {d_cpu:.0f}% of recorder CPU.")
print()

# Two competing predictions for B, from A.
pred_msg = mA * msgB / msgA
pred_byte = mA * mbB / mbA if mbA else mA
print(f" if cost were purely per-message, B would be ~{pred_msg:.3f} cores")
print(f" if cost were purely per-byte,    B would be ~{pred_byte:.3f} cores")
print(f" B measured                                  {mB:.3f} cores")
print()

# The two predictions bracket the answer, so report where the measurement falls
# BETWEEN them rather than forcing a binary. w = 1 is purely per-message, w = 0
# purely per-byte; a real system usually lands in between, and saying so is more
# useful than picking the nearer side of a midpoint.
span = pred_byte - pred_msg
if abs(span) < 0.02:
    print(" INCONCLUSIVE: the two predictions are too close together to tell apart.")
    print(" Cut a group that changes messages and bytes more differently.")
else:
    w = (pred_byte - mB) / span
    wc = max(0.0, min(1.0, w))
    print(f" => about {wc*100:.0f}% of recorder cost tracks MESSAGE COUNT,"
          f" {100-wc*100:.0f}% tracks BYTES.")
    if not (-0.15 < w < 1.15):
        print("    (measurement fell outside both predictions -- something else changed;")
        print("     check the repeat spread and whether the robot's workload was steady)")
    elif w > 0.7:
        print("    Decimating high-rate topics is the lever. The ablation study is worth running.")
    elif w < 0.3:
        print("    The thread-split reading was wrong. Re-think the profiles around payload,")
        print("    not message rate, before running the ablation.")
    else:
        print("    MIXED -- neither lever dominates. Both profiles need to cut messages AND")
        print("    bytes, and the ablation is worth running precisely because no single")
        print("    rule of thumb will predict what a given topic costs.")

if len(ac) > 1 and (max(ac) - min(ac)) > 0.25 * abs(mA - mB):
    print()
    print(" CAUTION: repeat-to-repeat spread in A is large next to the A/B difference.")
    print("          The robot was probably not doing the same thing throughout.")
    print("          Re-run with more repeats, or with the robot held in one state.")
PY

rm -f "${OUTDIR}"/.ac "${OUTDIR}"/.bc "${OUTDIR}"/.am "${OUTDIR}"/.bm "${OUTDIR}"/.ab "${OUTDIR}"/.bb
echo "=============================================================="
