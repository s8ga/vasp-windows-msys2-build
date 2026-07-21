#!/usr/bin/env bash
# =============================================================================
# install_optional.sh — orchestrate self-built optional libs for VASP (Windows)
#
# Builds HDF5 / LibXC / Wannier90 / DFTD4 into toolchain/install/<pkg>-<ver>,
# then writes the aggregate toolchain/install/setup for CMAKE_PREFIX_PATH.
#
# Usage (MSYS2 UCRT64, from repo root):
#   bash toolchain/scripts/install_optional.sh
#   OPTIONAL_LIBS="hdf5 libxc" bash toolchain/scripts/install_optional.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TOOLCHAIN_ROOT}/.." && pwd)"

# shellcheck source=../package_versions.sh
source "${TOOLCHAIN_ROOT}/package_versions.sh"
# shellcheck source=../lib/tool_kit.sh
source "${TOOLCHAIN_ROOT}/lib/tool_kit.sh"

SCRIPT_NAME="install_optional.sh"
BUILDDIR="${TOOLCHAIN_BUILDDIR:-${TOOLCHAIN_ROOT}/build}"
INSTALL_ROOT="${TOOLCHAIN_INSTALL_ROOT:-${TOOLCHAIN_ROOT}/install}"
OPTIONAL_LIBS="${OPTIONAL_LIBS:-hdf5 libxc wannier90 dftd4}"
# 0 = run real install scripts (default); 1 = pin-check only
OPTIONAL_LIBS_STUB="${OPTIONAL_LIBS_STUB:-0}"

mkdir -p "${BUILDDIR}" "${INSTALL_ROOT}"

log() { printf '\033[1;34m[optional]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

install_one() {
  local pkg="$1"
  local script="${SCRIPT_DIR}/install_${pkg}.sh"
  [ -f "${script}" ] || die "missing ${script}"
  log "--- ${pkg} ---"
  if [ "${OPTIONAL_LIBS_STUB}" = "1" ]; then
    log "STUB: would run ${script} (OPTIONAL_LIBS_STUB=1)"
    load_package_vars "${pkg}" || die "load_package_vars ${pkg} failed"
    log "pin OK for ${pkg}"
    return 0
  fi
  bash "${script}"
}

log "REPO_ROOT=${REPO_ROOT}"
log "BUILDDIR=${BUILDDIR}"
log "INSTALL_ROOT=${INSTALL_ROOT}"
log "jobs=$(toolchain_jobs)"
log "libs: ${OPTIONAL_LIBS}"

for pkg in ${OPTIONAL_LIBS}; do
  install_one "${pkg}"
done

log "writing aggregate setup ..."
bash "${SCRIPT_DIR}/write_aggregate_setup.sh"

log "done (stub=${OPTIONAL_LIBS_STUB}). Source: ${INSTALL_ROOT}/setup"
