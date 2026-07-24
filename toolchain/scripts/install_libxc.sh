#!/usr/bin/env bash
# =============================================================================
# install_libxc.sh — build LibXC into toolchain/install/libxc-<ver>
#
# Adapted from ABACUS toolchain/scripts/stage3/install_libxc.sh.
# Pins: toolchain/package_versions.sh (libxc_ver / sha256 / url).
# Checksum: retrieve_package + verify_before_extract before tar (never blind unpack).
# Requires: MSYS2 UCRT64 (cmake, gfortran, make or ninja).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../package_versions.sh
source "${TOOLCHAIN_ROOT}/package_versions.sh"
# shellcheck source=../lib/tool_kit.sh
source "${TOOLCHAIN_ROOT}/lib/tool_kit.sh"

SCRIPT_NAME="install_libxc.sh"
load_package_vars libxc

BUILDDIR="${TOOLCHAIN_BUILDDIR:-${TOOLCHAIN_ROOT}/build}"
INSTALL_ROOT="${TOOLCHAIN_INSTALL_ROOT:-${TOOLCHAIN_ROOT}/install}"
LOG_LINES="${LOG_LINES:-200}"

pkg_install_dir="${INSTALL_ROOT}/libxc-${libxc_ver}"
install_lock_file="${pkg_install_dir}/install_successful"
libxc_pkg="$(basename "${libxc_url}")"

log() { printf '\033[1;34m[libxc]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[libxc]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "${BUILDDIR}" "${INSTALL_ROOT}"
cd "${BUILDDIR}"

write_setup_snippet() {
  # Consumed later by install_optional.sh; also kept under the install prefix.
  local setup_build="${BUILDDIR}/setup_libxc"
  local setup_prefix="${pkg_install_dir}/setup_libxc"
  cat > "${setup_build}" << EOF
# LibXC ${libxc_ver} — source from an MSYS2 UCRT64 shell before cmake configure
prepend_path CMAKE_PREFIX_PATH "${pkg_install_dir}"
prepend_path PKG_CONFIG_PATH "${pkg_install_dir}/lib/pkgconfig"
prepend_path PATH "${pkg_install_dir}/bin"
prepend_path LD_LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path LIBRARY_PATH "${pkg_install_dir}/lib"
export LIBXC_ROOT="${pkg_install_dir}"
EOF
  mkdir -p "${pkg_install_dir}"
  cp -f "${setup_build}" "${setup_prefix}"
  log "wrote setup snippet: ${setup_build}"
  log "wrote setup snippet: ${setup_prefix}"
}

if [ -f "${install_lock_file}" ]; then
  log "libxc-${libxc_ver} already installed at ${pkg_install_dir}, skipping build."
  write_setup_snippet
  report_timing "libxc"
  exit 0
fi

log "==================== Installing LIBXC ${libxc_ver} ===================="
log "prefix=${pkg_install_dir}"
log "builddir=${BUILDDIR}"

retrieve_package "${libxc_sha256}" "${libxc_pkg}" "${libxc_url}"

src_dir="libxc-${libxc_ver}"
[ -d "${src_dir}" ] && rm -rf "${src_dir}"

# Re-verify pin immediately before unpack (central gate; never blind extract).
verify_before_extract "${libxc_sha256}" "${libxc_pkg}" || die "SHA256 verify failed for ${libxc_pkg}"

# GitLab archives may contain symlinks (README/ChangeLog); on Windows/MSYS2
# create .lnk stubs instead of failing extract. Archive was already SHA256-checked.
export MSYS="${MSYS:+$MSYS }winsymlinks:lnk"
case "${libxc_pkg}" in
  *.tar.bz2) tar -xjf "${libxc_pkg}" || true ;;
  *.tar.gz|*.tgz) tar -xzf "${libxc_pkg}" || true ;;
  *.tar.xz) tar -xJf "${libxc_pkg}" || true ;;
  *) die "unsupported archive format: ${libxc_pkg}" ;;
esac

[ -f "${src_dir}/CMakeLists.txt" ] || die "expected ${src_dir}/CMakeLists.txt after extract"

cmake_build="${src_dir}/build"
rm -rf "${cmake_build}"
mkdir -p "${cmake_build}"
cd "${cmake_build}"

log "cmake configure (ENABLE_FORTRAN=ON)..."
cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${pkg_install_dir}" \
  -DBUILD_SHARED_LIBS=YES \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_VERBOSE_MAKEFILE=ON \
  -DENABLE_FORTRAN=ON \
  -DENABLE_PYTHON=OFF \
  -DDISABLE_FHC=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_TESTING=OFF \
  .. > configure.log 2>&1 || {
  tail -n "${LOG_LINES}" configure.log >&2
  die "cmake configure failed (see ${cmake_build}/configure.log)"
}

jobs="$(toolchain_jobs)"
log "build -j${jobs}..."
if command -v ninja >/dev/null 2>&1 && [ -f build.ninja ]; then
  ninja -j"${jobs}" > make.log 2>&1 || {
    tail -n "${LOG_LINES}" make.log >&2
    die "ninja build failed (see ${cmake_build}/make.log)"
  }
  ninja install > install.log 2>&1 || {
    tail -n "${LOG_LINES}" install.log >&2
    die "ninja install failed (see ${cmake_build}/install.log)"
  }
else
  make -j"${jobs}" > make.log 2>&1 || {
    tail -n "${LOG_LINES}" make.log >&2
    die "make failed (see ${cmake_build}/make.log)"
  }
  make install > install.log 2>&1 || {
    tail -n "${LOG_LINES}" install.log >&2
    die "make install failed (see ${cmake_build}/install.log)"
  }
fi

# Lock file marks a successful install (content is a simple stamp).
{
  echo "libxc-${libxc_ver}"
  echo "sha256=${libxc_sha256}"
  date -u '+%Y-%m-%dT%H:%M:%SZ'
} > "${install_lock_file}"

write_setup_snippet

log "OK: LibXC ${libxc_ver} -> ${pkg_install_dir}"
report_timing "libxc"

