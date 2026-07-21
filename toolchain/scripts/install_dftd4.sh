#!/usr/bin/env bash
# =============================================================================
# install_dftd4.sh — build DFT-D4 into toolchain/install/dftd4-<ver>
#
# Adapted from ABACUS toolchain/scripts/stage4/install_dftd4.sh (cmake install).
# Critical for VASP: -DWITH_API_V2=ON (ABACUS does not set this).
# Checksum: retrieve_package + extract_verified_archive (never blind unpack).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../package_versions.sh
source "${TOOLCHAIN_ROOT}/package_versions.sh"
# shellcheck source=../lib/tool_kit.sh
source "${TOOLCHAIN_ROOT}/lib/tool_kit.sh"

SCRIPT_NAME="install_dftd4.sh"
load_package_vars dftd4

BUILDDIR="${TOOLCHAIN_BUILDDIR:-${TOOLCHAIN_ROOT}/build}"
INSTALL_ROOT="${TOOLCHAIN_INSTALL_ROOT:-${TOOLCHAIN_ROOT}/install}"
pkg_install_dir="${INSTALL_ROOT}/dftd4-${dftd4_ver}"
install_lock_file="${pkg_install_dir}/install_successful"
dftd4_pkg="dftd4-${dftd4_ver}.tar.xz"
url="${dftd4_url}"
setup_file="${BUILDDIR}/setup_dftd4"

mkdir -p "${BUILDDIR}" "${INSTALL_ROOT}"
cd "${BUILDDIR}"

log() { printf '\033[1;34m[dftd4]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dftd4]\033[0m %s\n' "$*" >&2; exit 1; }

# Same Fortran driver as the VASP UCRT64 stack.
export FC="${FC:-gfortran}"
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"

command -v cmake >/dev/null 2>&1 || die "cmake not found (UCRT64)"
command -v "${FC}" >/dev/null 2>&1 || die "${FC} not found (UCRT64)"
command -v ninja >/dev/null 2>&1 || die "ninja not found (UCRT64)"

if [ -f "${install_lock_file}" ] && [ -f "${pkg_install_dir}/lib/cmake/dftd4/dftd4-config.cmake" ]; then
  log "dftd4-${dftd4_ver} already installed at ${pkg_install_dir}, skipping build."
else
  log "==================== Installing DFT-D4 ${dftd4_ver} ===================="
  retrieve_package "${dftd4_sha256}" "${dftd4_pkg}" "${url}"

  log "Installing from scratch into ${pkg_install_dir}"
  rm -rf "dftd4-${dftd4_ver}"
  extract_verified_archive "${dftd4_sha256}" "${dftd4_pkg}"
  cd "dftd4-${dftd4_ver}"

  rm -rf build
  mkdir build && cd build

  # Prefer system OpenBLAS / LAPACK from MINGW_PREFIX when present (ABACUS pattern).
  _cmake_prefix="${MINGW_PREFIX:-/ucrt64}"
  if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    _cmake_prefix="${CMAKE_PREFIX_PATH}:${_cmake_prefix}"
  fi

  log "FC=${FC} CC=${CC} CXX=${CXX}"
  log "cmake configure (Ninja, WITH_API_V2=ON) ..."
  CMAKE_PREFIX_PATH="${_cmake_prefix}" cmake -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${pkg_install_dir}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_Fortran_COMPILER="${FC}" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DWITH_API=ON \
    -DWITH_API_V2=ON \
    -DCMAKE_VERBOSE_MAKEFILE=ON \
    .. > cmake.log 2>&1 || {
      tail -n 80 cmake.log >&2 || true
      die "cmake configure failed; see ${BUILDDIR}/dftd4-${dftd4_ver}/build/cmake.log"
    }

  # Confirm API_V2 landed in the cache (VASP requires it).
  if ! grep -qE 'WITH_API_V2:(BOOL|STRING)=ON' CMakeCache.txt 2>/dev/null; then
    die "WITH_API_V2=ON not present in CMakeCache.txt after configure"
  fi
  log "CMakeCache confirms WITH_API_V2=ON"

  njobs="$(toolchain_jobs)"
  log "cmake --build / install -j${njobs} ..."
  cmake --build . --parallel "${njobs}" > build.log 2>&1 || {
    tail -n 80 build.log >&2 || true
    die "build failed; see ${BUILDDIR}/dftd4-${dftd4_ver}/build/build.log"
  }
  cmake --install . > install.log 2>&1 || {
    tail -n 80 install.log >&2 || true
    die "cmake --install failed; see ${BUILDDIR}/dftd4-${dftd4_ver}/build/install.log"
  }

  [ -f "${pkg_install_dir}/lib/cmake/dftd4/dftd4-config.cmake" ] || \
    die "missing ${pkg_install_dir}/lib/cmake/dftd4/dftd4-config.cmake"

  # Minimal lock marker (path of this script for traceability).
  printf '%s\n' "${SCRIPT_DIR}/${SCRIPT_NAME}" > "${install_lock_file}"
  log "install OK -> ${pkg_install_dir}"
fi

# Self-contained setup snippet for later concatenation by install_optional.sh
cat > "${setup_file}" << EOF
export DFTD4_VER="${dftd4_ver}"
export DFTD4_ROOT="${pkg_install_dir}"
prepend_path PATH "${pkg_install_dir}/bin"
prepend_path LD_LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path CPATH "${pkg_install_dir}/include"
prepend_path PKG_CONFIG_PATH "${pkg_install_dir}/lib/pkgconfig"
prepend_path CMAKE_PREFIX_PATH "${pkg_install_dir}"
EOF

log "wrote ${setup_file}"
log "DFTD4_ROOT=${pkg_install_dir}"
report_timing "dftd4"
