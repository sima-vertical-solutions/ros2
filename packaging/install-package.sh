#!/usr/bin/env bash
#
# Installed by `sima-cli neat install ros2`. sima-cli downloads the package
# resources into a directory and runs this from inside it.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

shopt -s nullglob
debs=(ros2_*_arm64.deb)
shopt -u nullglob

if (( ${#debs[@]} != 1 )); then
    echo "Expected exactly one ros2 package here, found ${#debs[@]}." >&2
    exit 1
fi

sudo=""
if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null || { echo "Need root or sudo to install." >&2; exit 1; }
    sudo=sudo
fi

# apt rather than dpkg so the package's declared dependencies are resolved
# from the configured repositories instead of leaving it half-configured.
${sudo} apt-get update
${sudo} apt-get install -y "./${debs[0]}"

echo "Installed ${debs[0]} under /usr/local/ros2."
echo "Run: source /usr/local/ros2/local_setup.bash"
