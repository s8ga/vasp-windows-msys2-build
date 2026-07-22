#!/usr/bin/env bash
# =============================================================================
# write_aggregate_setup.sh — assemble toolchain/install/setup from setup_* snippets
#
# Sources/copies setup_hdf5, setup_libxc, setup_wannier90, setup_dftd4,
# setup_vtst so that CMAKE_PREFIX_PATH lists toolchain prefixes before
# MINGW_PREFIX (caller appends). setup_vtst exports VTST_CODE_DIR when present.
#
# Usage (MSYS2 UCRT64):
#   bash toolchain/scripts/write_aggregate_setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../package_versions.sh
source "${TOOLCHAIN_ROOT}/package_versions.sh"

INSTALL_ROOT="${TOOLCHAIN_INSTALL_ROOT:-${TOOLCHAIN_ROOT}/install}"
BUILDDIR="${TOOLCHAIN_BUILDDIR:-${TOOLCHAIN_ROOT}/build}"
OUT="${INSTALL_ROOT}/setup"

mkdir -p "${INSTALL_ROOT}"

# Collect per-package snippets into INSTALL_ROOT/setup_<pkg> when possible.
copy_snip() {
  local name="$1"
  shift
  local dest="${INSTALL_ROOT}/${name}"
  local cand
  for cand in "$@"; do
    if [ -f "${cand}" ]; then
      if [ "${cand}" -ef "${dest}" ] 2>/dev/null || [ "${cand}" = "${dest}" ]; then
        return 0
      fi
      cp -f "${cand}" "${dest}"
      return 0
    fi
  done
  return 1
}

copy_snip setup_hdf5 \
  "${INSTALL_ROOT}/setup_hdf5" \
  "${BUILDDIR}/setup_hdf5" \
  "${INSTALL_ROOT}/hdf5-${hdf5_ver}/setup_hdf5.env" || true

copy_snip setup_libxc \
  "${INSTALL_ROOT}/libxc-${libxc_ver}/setup_libxc" \
  "${BUILDDIR}/setup_libxc" || true

# Wannier setup is path-relative to its prefix; keep a thin wrapper at install root.
if [ -f "${INSTALL_ROOT}/wannier90-${wannier90_ver}/setup_wannier90" ]; then
  cat > "${INSTALL_ROOT}/setup_wannier90" << EOF
# Wrapper — sources prefix-local setup (WANNIER90_ROOT via BASH_SOURCE)
# shellcheck disable=SC1091
source "${INSTALL_ROOT}/wannier90-${wannier90_ver}/setup_wannier90"
EOF
fi

copy_snip setup_dftd4 \
  "${BUILDDIR}/setup_dftd4" \
  "${INSTALL_ROOT}/dftd4-${dftd4_ver}/setup_dftd4" || true

copy_snip setup_vtst \
  "${INSTALL_ROOT}/setup_vtst" \
  "${BUILDDIR}/setup_vtst" \
  "${INSTALL_ROOT}/vtst-${vtst_ver}/setup_vtst.env" || true

cat > "${OUT}" << 'EOF'
# =============================================================================
# toolchain/install/setup — aggregate optional-lib environment (generated)
#
# Source from MSYS2 UCRT64 (do not execute):
#   source toolchain/install/setup
#
# Ensures CMAKE_PREFIX_PATH lists toolchain prefixes first. Callers that need
# pacman packages should append MINGW_PREFIX afterward (env_ucrt64 / pipeline).
# =============================================================================

_tc_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Minimal path helpers (same semantics as toolchain/lib/tool_kit.sh)
if ! declare -F prepend_path >/dev/null 2>&1; then
  remove_path() {
    local __path_name=$1
    local __directory=$2
    local __path
    eval "__path=\${${__path_name}:-}"
    __path=${__path//:$__directory:/:}
    __path=${__path#$__directory:}
    __path=${__path%:$__directory}
    __path=$(echo "$__path" | sed "s#^$__directory\$##g")
    eval "${__path_name}=\"${__path}\""
    eval "export ${__path_name}"
  }
  prepend_path() {
    remove_path "$1" "$2"
    eval "$1=\"$2\${$1:+\":\$$1\"}\""
    eval "export $1"
  }
fi

# Source in a stable order. Each snippet prepends, so later snippets sit leftmost;
# all toolchain prefixes remain ahead of any MINGW_PREFIX the caller appends.
for _snip in setup_hdf5 setup_libxc setup_wannier90 setup_dftd4 setup_vtst; do
  if [ -f "${_tc_setup_dir}/${_snip}" ]; then
    # shellcheck disable=SC1090
    source "${_tc_setup_dir}/${_snip}"
  fi
done
unset _snip

# Drop accidental MINGW_PREFIX from the left so toolchain stays first; callers
# re-append MINGW after sourcing this file.
if [ -n "${MINGW_PREFIX:-}" ]; then
  remove_path CMAKE_PREFIX_PATH "${MINGW_PREFIX}"
fi

unset _tc_setup_dir
EOF

printf '[setup] wrote %s\n' "${OUT}"
for _s in setup_hdf5 setup_libxc setup_wannier90 setup_dftd4 setup_vtst; do
  if [ -f "${INSTALL_ROOT}/${_s}" ]; then
    printf '[setup]   + %s\n' "${_s}"
  else
    printf '[setup]   - %s (missing)\n' "${_s}"
  fi
done
