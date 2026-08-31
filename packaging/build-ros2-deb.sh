#!/usr/bin/env bash
#
# Build the `ros2` Debian package from the pinned ros2.repos in this repository.
#
# This is a port of the ros2 recipe in swsoc-elxr-config
# (boards/arm64/simaai/packages/ros2/ros2.yaml), which cross-compiled from x86
# against an ARM64 sysroot under qemu. This runs natively on ARM64 instead, so
# a large amount of that recipe is gone:
#
#   dropped   -DCMAKE_SYSROOT, CMAKE_FIND_ROOT_PATH*, QEMU_LD_PREFIX
#   dropped   ~25 explicit -D*_LIBRARY= paths (X11, BLAS, OpenGL, freetype,
#             bullet, orocos-kdl, sqlite3, png, jpeg, assimp, lz4, zlib) --
#             those existed only because CMake could not probe a sysroot
#   dropped   the sed pass that stripped the sysroot prefix from installed files
#   kept      the yaml-cpp and freetype CMake shims -- those work around Debian
#             bookworm packaging, not cross-compilation
#   kept      the sed pass that strips the staging prefix, which is still needed
#
# Run inside the container built from packaging/Dockerfile.build, with this
# repository mounted at /workspace.
#
# Package metadata lives in packaging/control.in; the version comes from git
# tags. Neither is hardcoded here.
#
# Environment:
#   WORKDIR         scratch root                   (default /workspace/.build)
#   DISTDIR         where the .deb is written      (default /workspace/dist)
#   PKG_VERSION     overrides the version derived from git tags
#   SKIP_COLCON     reuse an already-staged tree instead of rebuilding
#   TAG_PREFIX      release tag namespace          (default sima/jazzy/v)
#   COLCON_WORKERS  parallel colcon packages       (default from available RAM)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-/workspace/.build}"
DISTDIR="${DISTDIR:-/workspace/dist}"

SRC="${WORKDIR}/src"
BUILD="${WORKDIR}/build"
STAGE="${WORKDIR}/stage"
INSTALL_PREFIX="/usr/local/ros2"

log() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- preflight --

# Checked before anything uses them, so a missing tool names itself rather than
# surfacing as "command not found" from whichever line happened to run first.
# dpkg-architecture and dpkg-deb both come from dpkg-dev.
for tool in vcs colcon dpkg-architecture dpkg-deb cc c++ make; do
    command -v "${tool}" >/dev/null || { echo "Missing required tool: ${tool}" >&2; exit 1; }
done

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
DEB_ARCH="$(dpkg-architecture -qDEB_HOST_ARCH)"

if [[ "${DEB_ARCH}" != arm64 ]]; then
    echo "This package is built natively for arm64; host is ${DEB_ARCH}." >&2
    echo "Building it anywhere else would emulate the whole ROS 2 tree." >&2
    exit 1
fi

# The reason packaging/Dockerfile.build refuses to contain ROS 2: an installed
# tree on AMENT_PREFIX_PATH would satisfy colcon's dependency resolution and
# packages would silently build against it instead of against each other.
if [[ -e "${INSTALL_PREFIX}" ]]; then
    echo "${INSTALL_PREFIX} already exists in this environment." >&2
    echo "colcon would resolve against it rather than the tree being built." >&2
    exit 1
fi

# ------------------------------------------------------------------ version --

# Derived from git tags, so a published package traces to one immutable ref.
#
#   at tag v2.0.1            -> 2.0.1
#   7 commits after it        -> 2.0.1+7.gabc123def456   (sorts ABOVE 2.0.1)
#   no such tag yet           -> 0~untagged.<date>.<sha> (sorts below everything)
#
# These are SiMa package versions, not upstream ROS 2 versions -- upstream has
# no 2.0.x, and this fork carries 114 of upstream's own tags. A bare
# `git describe --tags` here resolves to release-eloquent-20200124, which would
# version a Jazzy package after a ROS 2 release that went EOL in 2021. Matching
# v* prevents that: none of upstream's 114 tags start with v.
#
# No slash in the prefix, deliberately. A tag build publishes under the tag as
# its ref, and a slash is percent-encoded into the S3 key and again for the
# CDN -- so sima/jazzy/v2.0.1 would need sima%252Fjazzy%252Fv2.0.1 in a URL,
# the same trap the branch rename removed. v2.0.1 stays v2.0.1, and installs
# as `sima-cli neat install ros2@v2.0.1`.
#
# Requires full history and tags: pass fetch_depth: 0 to vulcan-build.yml, or
# actions/checkout with fetch-depth: 0 and fetch-tags: true.
TAG_PREFIX="${TAG_PREFIX:-v}"

if [[ -z "${PKG_VERSION:-}" ]]; then
    _sha="$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
    _match="${TAG_PREFIX}*"

    if _tag="$(git -C "${REPO_ROOT}" describe --tags --exact-match --match "${_match}" 2>/dev/null)"; then
        PKG_VERSION="${_tag#"${TAG_PREFIX}"}"
    elif _desc="$(git -C "${REPO_ROOT}" describe --tags --long --match "${_match}" 2>/dev/null)"; then
        # v2.0.1-7-gabc123 -> 2.0.1+7.gabc123
        _base="${_desc%-*-g*}"
        _count="${_desc#"${_base}"-}"; _count="${_count%%-g*}"
        PKG_VERSION="${_base#"${TAG_PREFIX}"}+${_count}.g${_sha}"
    else
        # Sorts below any real release, and below the 2.0.0 already published
        # to repo.sima.ai -- so an untagged build cannot quietly supersede it.
        PKG_VERSION="0~untagged.$(date -u +%Y%m%d).${_sha}"
    fi
fi

# dpkg is the authority on whether what we just built is a legal version.
if ! dpkg --validate-version "${PKG_VERSION}" 2>/dev/null; then
    echo "Computed version is not a valid Debian version: ${PKG_VERSION}" >&2
    exit 1
fi

# ------------------------------------------------------------- parallelism --
#
# The eLxr recipe used `--executor sequential --parallel-workers 1` with
# MAKEFLAGS=-j8. That was a concession to building under qemu, not a property
# of the build. Native, real parallelism is the single largest speedup here.
#
# The limit is memory, not cores: the heavier C++ packages (rviz, rclcpp,
# rosbag2) want roughly 2 GB per concurrent compile.

if [[ -z "${COLCON_WORKERS:-}" ]]; then
    _mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)"
    _by_mem=$(( _mem_gb / 2 ))
    _by_cpu="$(nproc)"
    COLCON_WORKERS=$(( _by_mem < _by_cpu ? _by_mem : _by_cpu ))
    (( COLCON_WORKERS < 1 )) && COLCON_WORKERS=1
fi

log "ros2 ${PKG_VERSION} (${DEB_ARCH}), ${COLCON_WORKERS} workers, $(nproc) cpus"

# --------------------------------------------------------------- fetch --

if [[ -n "${SKIP_COLCON:-}" && -d "${STAGE}${INSTALL_PREFIX}" ]]; then
    log "Reusing the staged tree; skipping fetch and colcon"
    mkdir -p "${DISTDIR}"
else

log "Importing sources from ros2.repos"

rm -rf "${WORKDIR}"
mkdir -p "${SRC}" "${BUILD}" "${STAGE}${INSTALL_PREFIX}" "${DISTDIR}"

# The repos file in THIS repository, not the one inside an upstream ros2/ros2
# checkout. This is what points rosbag2 at the SiMa fork carrying the CMA
# page-cache eviction fix in rosbag2_storage_mcap.
vcs import --input "${REPO_ROOT}/ros2.repos" "${SRC}"

grep -A2 '^  ros2/rosbag2:' "${REPO_ROOT}/ros2.repos"
git -C "${SRC}/ros2/rosbag2" log --oneline -1

# ------------------------------------------------- Debian bookworm CMake shims --
#
# Neither of these is about cross-compilation, so both survive the port.

log "Applying Debian bookworm CMake shims"

# bookworm's yaml-cpp 0.7 exports the target `yaml-cpp`, but ROS 2 looks for
# the namespaced `yaml-cpp::yaml-cpp`.
YAML_TARGETS="/usr/lib/${MULTIARCH}/cmake/yaml-cpp/yaml-cpp-targets.cmake"
if [[ -f "${YAML_TARGETS}" ]] && ! grep -q 'yaml-cpp::yaml-cpp' "${YAML_TARGETS}"; then
    cat >> "${YAML_TARGETS}" <<'CMAKE'
if(NOT TARGET yaml-cpp::yaml-cpp)
  add_library(yaml-cpp::yaml-cpp ALIAS yaml-cpp)
endif()
CMAKE
fi

# bookworm ships no freetype-config.cmake, so rviz_ogre_vendor cannot find the
# `freetype` / `freetype::freetype` targets it expects.
mkdir -p "/usr/lib/${MULTIARCH}/cmake/freetype"
cat > "/usr/lib/${MULTIARCH}/cmake/freetype/freetype-config.cmake" <<'CMAKE'
find_package(Freetype REQUIRED)
if(TARGET Freetype::Freetype AND NOT TARGET freetype::freetype)
    add_library(freetype::freetype ALIAS Freetype::Freetype)
endif()
if(TARGET Freetype::Freetype AND NOT TARGET freetype)
    add_library(freetype ALIAS Freetype::Freetype)
endif()
CMAKE

# ---------------------------------------------------------------- build --

log "Building with colcon"

# Deliberately NOT --merge-install: ros2.yaml does not use it, and it would
# change the installed layout under ${INSTALL_PREFIX}, making the result
# undiffable against the deb currently published to repo.sima.ai. Worth
# revisiting as a separate change if build disk turns out to be tight.
colcon build \
    --base-paths "${SRC}" \
    --build-base "${BUILD}" \
    --install-base "${STAGE}${INSTALL_PREFIX}" \
    --parallel-workers "${COLCON_WORKERS}" \
    --event-handlers console_direct+ \
    --cmake-args \
        -DBUILD_TESTING=OFF \
        -DCMAKE_BUILD_TYPE=Release

fi   # end SKIP_COLCON

# colcon writes its own absolute paths into the generated setup scripts and
# CMake config files. They currently point at the staging directory; strip that
# so they resolve correctly once the package is installed at ${INSTALL_PREFIX}.
log "Rewriting staging paths in generated files"

# ros2.yaml matched a fixed list of extensions here (*.sh, *.bash, *.zsh,
# *.py, *.ps1, *.cmake). That misses
# share/ament_index/resource_index/parent_prefix_path/<pkg>, which has no
# extension and holds the prefix path ament_index resolves against at runtime
# -- so the published package almost certainly carries a build-machine path in
# every one of those files.
#
# Selecting by content instead of by name means the rewrite and the check below
# operate on exactly the same set and cannot disagree. grep -I skips binaries,
# which must not be sed-ed.
mapfile -t rewrite < <(grep -rIl "${STAGE}" "${STAGE}${INSTALL_PREFIX}" || true)
if (( ${#rewrite[@]} > 0 )); then
    printf '%s\0' "${rewrite[@]}" | xargs -0 sed -i "s|${STAGE}||g"
    echo "rewrote ${#rewrite[@]} files"
fi

leftovers="$(grep -rIl "${STAGE}" "${STAGE}${INSTALL_PREFIX}" || true)"
if [[ -n "${leftovers}" ]]; then
    echo "Staging path still present in installed files after rewrite:" >&2
    printf '%s\n' "${leftovers}" | head -20 >&2
    exit 1
fi

# Binaries are excluded above, but a staging path baked into an RPATH would be
# just as broken. Report rather than fail: this has never been checked before,
# and a first run should not be gated on an unknown.
if command -v readelf >/dev/null; then
    while IFS= read -r so; do
        if readelf -d "${so}" 2>/dev/null | grep -q "${STAGE}"; then
            echo "WARNING: staging path in RPATH: ${so}" >&2
        fi
    done < <(find "${STAGE}${INSTALL_PREFIX}" -name '*.so*' -type f | head -200)
fi

# ---------------------------------------------------------------- package --

log "Assembling the Debian package"

# paste -d takes a LIST of delimiters and cycles through them, so -d ', '
# alternates comma and space and yields "acl,curl file,graphviz". Join on a
# single comma, then space it out.
DEPENDS="$(grep -vE '^\s*(#|$)' "${REPO_ROOT}/packaging/runtime-depends.txt" \
    | paste -sd , - | sed 's/,/, /g')"
INSTALLED_KB="$(du -sk "${STAGE}" | cut -f1)"

mkdir -p "${STAGE}/DEBIAN"
sed -e '/^#/d' \
    -e "s|@VERSION@|${PKG_VERSION}|" \
    -e "s|@ARCH@|${DEB_ARCH}|" \
    -e "s|@INSTALLED_SIZE@|${INSTALLED_KB}|" \
    -e "s|@DEPENDS@|${DEPENDS}|" \
    "${REPO_ROOT}/packaging/control.in" > "${STAGE}/DEBIAN/control"

if grep -q '@[A-Z_]*@' "${STAGE}/DEBIAN/control"; then
    echo "Unsubstituted placeholder left in the control file:" >&2
    grep -n '@[A-Z_]*@' "${STAGE}/DEBIAN/control" >&2
    exit 1
fi

echo "--- DEBIAN/control ---"
cat "${STAGE}/DEBIAN/control"
echo "---------------------"

DEB="${DISTDIR}/ros2_${PKG_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --root-owner-group --build "${STAGE}" "${DEB}"

# ---------------------------------------------------------------- verify --

log "Verifying the package"

dpkg-deb --info "${DEB}"

# The patch is the reason this package exists rather than the one already on
# repo.sima.ai. Fail here rather than discovering it on the devkit.
MCAP_PLUGIN="$(find "${STAGE}${INSTALL_PREFIX}" -name 'librosbag2_storage_mcap.so' -print -quit)"
if [[ -z "${MCAP_PLUGIN}" ]]; then
    echo "librosbag2_storage_mcap.so was not built." >&2
    exit 1
fi

# FadviseWriter has virtual methods, so its mangled name lands in the typeinfo
# strings. Crude, but it distinguishes the fork from stock rosbag2 without
# needing to run anything.
if ! grep -aq FadviseWriter "${MCAP_PLUGIN}"; then
    echo "${MCAP_PLUGIN} does not contain FadviseWriter." >&2
    echo "The build used stock rosbag2, not the SiMa fork." >&2
    exit 1
fi

log "Built $(basename "${DEB}") ($(du -h "${DEB}" | cut -f1))"
