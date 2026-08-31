#!/usr/bin/env bash
#
# Smoke-test the built ros2 package in a clean Debian bookworm container.
#
#   docker run --rm \
#     --volume "${PWD}/dist:/dist:ro" \
#     --volume "${PWD}/packaging:/packaging:ro" \
#     debian:bookworm /packaging/smoke-test.sh
#
# This lives in a file rather than inline in the workflow because inline it
# needs three levels of quoting -- the YAML block, `bash -c` for docker run,
# and `sh -c` inside the ldd loop -- and the innermost quotes terminate the
# outermost string. That broke the run twice before this file existed.

set -euo pipefail

PREFIX=/usr/local/ros2

echo "=== installing the package ==="
apt-get update -qq
# Installing from a stock bookworm base is the assertion: apt has to satisfy
# every dependency the package declares, from Debian alone.
apt-get install -y -qq /dist/ros2_*.deb

echo
echo "=== sourcing the ROS 2 environment ==="
set +u
# shellcheck disable=SC1091
source "${PREFIX}/local_setup.bash"
set -u

echo
echo "=== unresolved system libraries ==="
# Most of what this tree links against, it also builds; those resolve through
# LD_LIBRARY_PATH rather than a system path. Hence sourcing the environment
# first, and discounting anything the package itself ships -- without both,
# the scan reports ~245 false positives.
find "${PREFIX}" -name '*.so*' -printf '%f\n' | sort -u > /tmp/shipped

# ldd exits non-zero on anything that is not a dynamic executable, and
# -perm -u+x matches every shell script in the tree, so each call has to be
# allowed to fail.
find "${PREFIX}" -type f \( -name '*.so*' -o -perm -u+x \) -print0 \
    | while IFS= read -r -d '' f; do ldd "${f}" 2>/dev/null || true; done \
    | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p' \
    | sort -u > /tmp/unresolved

comm -23 /tmp/unresolved /tmp/shipped > /tmp/missing
if [[ -s /tmp/missing ]]; then
    cat /tmp/missing
    echo "^^ undeclared runtime dependencies -- add them to packaging/runtime-depends.txt" >&2
    exit 1
fi
echo "none"

echo
echo "=== smoke test ==="
ros2 --help > /dev/null
ros2 pkg prefix rosbag2_storage
echo "ros2 installs and runs."
