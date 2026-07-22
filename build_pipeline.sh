#!/usr/bin/env bash
# =============================================================================
# build_pipeline.sh — VASP 6.6.x Windows-native build (MSYS2 UCRT64, C2 route)
#
# Modes (VASP_PIPELINE_MODE):
#   release (default) — full pipeline: tarball --> portable green ZIP
#                       WORK_DIR defaults to build_work/<flavor>/<stamp>/
#   develop           — reuse CURRENT (or explicit WORK_DIR), stop after build
#                       (no unpack wipe, no harvest/package/zip)
#
# Flavor (VASP_VTST): OFF → stock (default); ON → vtst (+ PKG_NAME -vtst suffix)
#
# Run inside an MSYS2 *UCRT64* shell:
#     VASP_TARBALL=/c/path/to/vasp.6.6.0.tgz bash build_pipeline.sh
#     bash build_pipeline.sh /c/path/to/vasp.6.6.0.tgz
#     VASP_PIPELINE_MODE=develop VASP_TARBALL=... bash build_pipeline.sh
#     bash build_pipeline.sh --develop /c/path/to/vasp.6.6.0.tgz
#     VASP_VTST=ON VTST_CODE_DIR=/c/path/to/vtstcode6.6.0 bash build_pipeline.sh
#
# VASP_TARBALL may be MSYS (/c/...) or Windows (C:\... / C:/...); preflight
# normalizes via to_msys_path before the existence check.
#
# Co-located assets (relative to this script):
#   ./vasp_cmake/        official CMake port (setup.sh, CMakeLists/, Find*.cmake)
#   ./patches/           0001/0002 timing + 0003 DFTD4 + 0004 Win32 MAXMEM + 0005 BSE AVpW
#   ./shim/              MS-MPI wrap, FFTW, Win32 available-memory helper
#   ./cmake_overlays/    FindDFTD4.cmake / FindLibXC.cmake (copied into staged cmake/)
#   ./toolchain/install/ self-built HDF5/LibXC/Wannier90/DFTD4 (via install/setup)
#   ./toolchain/scripts/inject_vtst.sh  optional VTST overlay (when VASP_VTST=ON)
#
# release stages: preflight, unpack, setup, patch, inject_vtst, configure, build,
#                 harvest, package, zip, write CURRENT
# develop stages: preflight, locate tree, patch, inject_vtst, (configure if needed),
#                 build
# =============================================================================
set -euo pipefail

#-----------------------------------------------------------------------------
# Configuration (override via environment)
#-----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VASP_PIPELINE_MODE="${VASP_PIPELINE_MODE:-release}"
VASP_TARBALL="${VASP_TARBALL:-}"
VASP_CMAKE_DIR="${VASP_CMAKE_DIR:-${SCRIPT_DIR}/vasp_cmake}"
PATCH_DIR="${PATCH_DIR:-${SCRIPT_DIR}/patches}"
CMAKE_OVERLAY_DIR="${CMAKE_OVERLAY_DIR:-${SCRIPT_DIR}/cmake_overlays}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${SCRIPT_DIR}/toolchain}"
# WORK_DIR: if unset, resolve_flavor_and_work_dir() picks
#   release → build_work/<flavor>/<stamp>/
#   develop → path from build_work/<flavor>/CURRENT
# Explicit WORK_DIR is always respected.
WORK_DIR_FROM_ENV="${WORK_DIR:-}"
WORK_DIR=""
BUILD_DIR_NAME="${BUILD_DIR_NAME:-build}"
PKG_NAME="${PKG_NAME:-vasp-6.6.0-msys2-portable}"
MINGW_PREFIX="${MINGW_PREFIX:-/ucrt64}"
TARGET_CPU="${TARGET_CPU:-x86-64}"
BUILD_VARIANTS="${BUILD_VARIANTS:-vasp_std vasp_gam vasp_ncl}"
# CMake build type (Release default). Use RelWithDebInfo for gdb file:line stacks.
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
# Optional features (ON/OFF). Disable individually if configure/link fails.
VASP_HDF5="${VASP_HDF5:-ON}"
VASP_LIBXC="${VASP_LIBXC:-ON}"
VASP_WANNIER90="${VASP_WANNIER90:-ON}"
VASP_DFTD4="${VASP_DFTD4:-ON}"
# fftlib (dynamic FFTW). OFF = classic FFT path; useful for PBE0/SIGSEGV A/B.
VASP_FFTLIB="${VASP_FFTLIB:-ON}"
# OpenMP (ON default). OFF = diagnostic: no GOMP CRITICAL in fftbas_plan path.
VASP_OPENMP="${VASP_OPENMP:-ON}"
# Optional VTST (transition-state tools). ON → flavor=vtst, inject after patch,
# PKG_NAME gains -vtst. Requires VTST_CODE_DIR (checked by inject_vtst.sh).
VASP_VTST="${VASP_VTST:-OFF}"
VTST_CODE_DIR="${VTST_CODE_DIR:-}"
FLAVOR=""
# Experimental diagnostic only: replace VASP's named FFT planner CRITICAL
# with a native Win32 SRW lock. Default OFF: the mpi_waitall_ /MPIPRIV2/
# sentinel fix prevents the BSS corruption that previously damaged this lock.
VASP_GOMP_CRITICAL_WIN32="${VASP_GOMP_CRITICAL_WIN32:-OFF}"
# NUM_CORES — optional override for ninja -j (else RAM-capped nproc)
# Materialize testsuite/POTCARS relative symlinks as real files after unpack
# (Windows often fails to create those links; tar exits non-zero). Default ON.
VASP_MATERIALIZE_POTCAR_LINKS="${VASP_MATERIALIZE_POTCAR_LINKS:-1}"

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

# Join dirname + relative target and collapse . / .. (no absolute, no drive).
# Echoes normalized path relative to WORK_DIR / tarball root, or empty on failure.
_norm_rel_path() {
  local base="$1" rel="$2"
  local IFS='/'
  # shellcheck disable=SC2206
  local parts=( ${base} )
  local seg
  case "${rel}" in
    /*|[A-Za-z]:*) printf ''; return 1 ;;
  esac
  # shellcheck disable=SC2206
  local segs=( ${rel} )
  for seg in "${segs[@]}"; do
    case "${seg}" in
      ''|.) continue ;;
      ..)
        if [ "${#parts[@]}" -eq 0 ]; then printf ''; return 1; fi
        unset "parts[-1]"
        ;;
      *) parts+=("${seg}") ;;
    esac
  done
  if [ "${#parts[@]}" -eq 0 ]; then printf ''; return 1; fi
  local out="${parts[0]}"
  local i
  for ((i = 1; i < ${#parts[@]}; i++)); do
    out="${out}/${parts[i]}"
  done
  printf '%s' "${out}"
}

# After tar extract: copy relative testsuite/POTCARS symlink targets as real files.
# Catalog comes from tar -tvf (not find -type l on disk). Skips absolute / dangling / cycles.
materialize_potcar_links() {
  case "${VASP_MATERIALIZE_POTCAR_LINKS}" in
    0|false|FALSE|off|OFF|no|NO)
      log "POTCAR link materialize skipped (VASP_MATERIALIZE_POTCAR_LINKS=${VASP_MATERIALIZE_POTCAR_LINKS})"
      return 0
      ;;
  esac

  local -A link_map=()
  local line name target
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      l*"testsuite/POTCARS/"*" -> "*) ;;
      *) continue ;;
    esac
    target="${line##* -> }"
    name="${line%% -> *}"
    name="${name##* }"
    case "${name}" in
      *testsuite/POTCARS/*) ;;
      *) continue ;;
    esac
    case "${target}" in
      ''|/*|[A-Za-z]:*) continue ;;
    esac
    link_map["${name}"]="${target}"
  done < <(tar -tvf "${VASP_TARBALL}" 2>/dev/null || true)

  local materialized=0 skipped=0
  local cur nxt src dst dir visited hop
  for name in "${!link_map[@]}"; do
    cur="${name}"
    visited=""
    src=""
    for ((hop = 0; hop < 32; hop++)); do
      case " ${visited} " in
        *" ${cur} "*) src=""; break ;;
      esac
      visited="${visited} ${cur}"
      if [ -n "${link_map[${cur}]+x}" ]; then
        target="${link_map[${cur}]}"
        case "${target}" in
          /*|[A-Za-z]:*) src=""; break ;;
        esac
        dir="$(dirname "${cur}")"
        nxt="$(_norm_rel_path "${dir}" "${target}")" || { src=""; break; }
        [ -n "${nxt}" ] || { src=""; break; }
        cur="${nxt}"
        continue
      fi
      # Not a catalogued symlink: treat as leaf path under WORK_DIR.
      if [ -f "${WORK_DIR}/${cur}" ] && [ -s "${WORK_DIR}/${cur}" ]; then
        src="${WORK_DIR}/${cur}"
      else
        src=""
      fi
      break
    done

    dst="${WORK_DIR}/${name}"
    if [ -z "${src}" ] || [ ! -f "${src}" ] || [ ! -s "${src}" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    # Already a real non-empty copy of the same inode/size is fine; always refresh.
    mkdir -p "$(dirname "${dst}")"
    rm -f "${dst}"
    cp -f "${src}" "${dst}"
    materialized=$((materialized + 1))
  done

  log "materialized ${materialized} POTCAR link(s); skipped ${skipped} (absolute/dangling/cycle/empty)"
}

# Parse CLI: --develop / --help and optional tarball positional.
parse_args() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "${arg}" in
      --develop)
        VASP_PIPELINE_MODE=develop
        shift
        ;;
      --help|-h)
        cat <<'EOF'
Usage:
  VASP_TARBALL=/c/path/to/vasp.tgz bash build_pipeline.sh
  bash build_pipeline.sh /c/path/to/vasp.tgz
  VASP_PIPELINE_MODE=develop VASP_TARBALL=... bash build_pipeline.sh
  bash build_pipeline.sh --develop /c/path/to/vasp.tgz
  VASP_VTST=ON VTST_CODE_DIR=/c/path/to/vtstcode bash build_pipeline.sh

Modes (VASP_PIPELINE_MODE):
  release  full pipeline through portable ZIP (default)
           WORK_DIR = build_work/<stock|vtst>/<stamp>/ unless set
  develop  reuse CURRENT (or WORK_DIR); rebuild only; skip harvest/package/zip

Flavor (VASP_VTST=OFF|ON):
  OFF  stock tree; PKG_NAME = vasp-6.6.0-msys2-portable
  ON   vtst tree + inject; PKG_NAME gains -vtst; needs VTST_CODE_DIR
EOF
        exit 0
        ;;
      --*)
        die "unknown option: ${arg} (try --help)"
        ;;
      *)
        if [ -z "${VASP_TARBALL}" ]; then
          VASP_TARBALL="${arg}"
        else
          die "unexpected argument: ${arg}"
        fi
        shift
        ;;
    esac
  done
  case "${VASP_PIPELINE_MODE}" in
    release|develop) ;;
    *) die "invalid VASP_PIPELINE_MODE='${VASP_PIPELINE_MODE}' (use release or develop)" ;;
  esac
}

stage() { # stage <n> <name>
  log "[$1] $2"
}

#-----------------------------------------------------------------------------
# resolve_flavor_and_work_dir — flavor, PKG -vtst, WORK_DIR stamp/CURRENT
# Call after parse_args (mode known). Respects explicit WORK_DIR.
#-----------------------------------------------------------------------------
resolve_flavor_and_work_dir() {
  case "${VASP_VTST}" in
    ON|OFF) ;;
    *) die "VASP_VTST must be ON or OFF (got '${VASP_VTST}')" ;;
  esac

  if [ "${VASP_VTST}" = "ON" ]; then
    FLAVOR="vtst"
  else
    FLAVOR="stock"
  fi

  # Auto-append -vtst when ON (do not duplicate if already present).
  if [ "${VASP_VTST}" = "ON" ]; then
    case "${PKG_NAME}" in
      *-vtst) ;;
      *) PKG_NAME="${PKG_NAME}-vtst" ;;
    esac
  fi

  if [ -n "${WORK_DIR_FROM_ENV}" ]; then
    WORK_DIR="${WORK_DIR_FROM_ENV}"
    log "WORK_DIR (user override): ${WORK_DIR}"
  elif [ "${VASP_PIPELINE_MODE}" = "develop" ]; then
    local current_file="${SCRIPT_DIR}/build_work/${FLAVOR}/CURRENT"
    [ -f "${current_file}" ] \
      || die "develop: missing ${current_file} — run a ${FLAVOR} release first, or set WORK_DIR"
    WORK_DIR="$(tr -d '\r\n' < "${current_file}")"
    [ -n "${WORK_DIR}" ] || die "develop: ${current_file} is empty"
    [ -d "${WORK_DIR}" ] \
      || die "develop: CURRENT points to missing dir: ${WORK_DIR}"
    log "WORK_DIR (from ${FLAVOR}/CURRENT): ${WORK_DIR}"
  else
    # release: new per-build stamp under build_work/<flavor>/
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    WORK_DIR="${SCRIPT_DIR}/build_work/${FLAVOR}/${stamp}"
    log "WORK_DIR (new stamp): ${WORK_DIR}"
  fi

  export WORK_DIR FLAVOR PKG_NAME VASP_VTST
  [ -n "${VTST_CODE_DIR}" ] && export VTST_CODE_DIR
}

# After successful release package: point flavor CURRENT at this WORK_DIR.
write_flavor_current() {
  local flavor_root="${SCRIPT_DIR}/build_work/${FLAVOR}"
  local abs
  mkdir -p "${flavor_root}"
  abs="$(cd "${WORK_DIR}" && pwd)" || die "cannot resolve WORK_DIR for CURRENT: ${WORK_DIR}"
  printf '%s\n' "${abs}" > "${flavor_root}/CURRENT"
  log "updated ${flavor_root}/CURRENT -> ${abs}"
}

# Optional VTST overlay after patch_sources (release + develop).
# When ON: requires toolchain/scripts/inject_vtst.sh and VTST_CODE_DIR (script dies).
inject_vtst_sources() {
  if [ "${VASP_VTST}" != "ON" ]; then
    log "VASP_VTST=${VASP_VTST} — skip VTST inject"
    return 0
  fi
  local script="${SCRIPT_DIR}/toolchain/scripts/inject_vtst.sh"
  [ -f "${script}" ] \
    || die "VASP_VTST=ON but inject script missing: ${script}"
  stage "3b" "inject VTST (vtstcode overlay)"
  [ -n "${SRC_ROOT:-}" ] || die "SRC_ROOT unset before VTST inject"
  export SRC_ROOT VASP_VTST
  if [ -n "${VTST_CODE_DIR}" ]; then
    export VTST_CODE_DIR
  fi
  # Missing VTST_CODE_DIR → inject_vtst.sh dies with a clear message.
  bash "${script}" || die "VTST inject failed (VASP_VTST=ON)"
}

# Resolve the first existing path among several candidates; echo it, empty if none
first_existing() {
  local p
  for p in "$@"; do
    if [ -e "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# Cap ninja parallelism by available RAM (~3 GB per heavy TU).
# Override with NUM_CORES=<n> when set.
compute_jobs() {
  if [ -n "${NUM_CORES:-}" ]; then
    printf '%s' "${NUM_CORES}"
    return
  fi
  local jobs mem_gb
  jobs="$(nproc 2>/dev/null || echo 2)"
  if [ -r /proc/meminfo ]; then
    mem_gb="$(awk '/^MemTotal:/{printf "%d",$2/1024/1024}' /proc/meminfo)"
    if [ -n "${mem_gb:-}" ] && [ "${mem_gb:-0}" -ge 1 ]; then
      local by_mem=$(( mem_gb / 3 ))
      [ "${by_mem}" -lt 1 ] && by_mem=1
      [ "${by_mem}" -lt "${jobs}" ] && jobs="${by_mem}"
    fi
  fi
  printf '%s' "${jobs}"
}

# Resolve MINGW_PREFIX to a real path (Scoop installs often symlink /ucrt64).
resolve_mingw_prefix() {
  if [ -d "${MINGW_PREFIX}" ]; then
    MINGW_PREFIX_REAL="$(cd "${MINGW_PREFIX}" && pwd -P)"
  else
    MINGW_PREFIX_REAL="${MINGW_PREFIX}"
  fi
}

# Source toolchain/install/setup so CMAKE_PREFIX_PATH lists self-built prefixes
# before MINGW_PREFIX. Safe to call multiple times.
source_toolchain_optional() {
  local setup="${TOOLCHAIN_DIR}/install/setup"
  local writer="${TOOLCHAIN_DIR}/scripts/write_aggregate_setup.sh"
  if [ ! -f "${setup}" ] && [ -f "${writer}" ] && [ -d "${TOOLCHAIN_DIR}/install" ]; then
    bash "${writer}" >/dev/null 2>&1 || true
  fi
  if [ -f "${setup}" ]; then
    # shellcheck disable=SC1090
    source "${setup}"
    log "sourced ${setup}"
  else
    warn "toolchain/install/setup missing — optional libs may not be found"
  fi
  resolve_mingw_prefix
  case ":${CMAKE_PREFIX_PATH:-}:" in
    *":${MINGW_PREFIX}:"*) ;;
    *) export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:+${CMAKE_PREFIX_PATH}:}${MINGW_PREFIX}" ;;
  esac
  # Realpath form of install root for DLL harvest matching
  if [ -d "${TOOLCHAIN_DIR}/install" ]; then
    TOOLCHAIN_INSTALL_REAL="$(cd "${TOOLCHAIN_DIR}/install" && pwd -P)"
  else
    TOOLCHAIN_INSTALL_REAL="${TOOLCHAIN_DIR}/install"
  fi
  export TOOLCHAIN_INSTALL_REAL
  log "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH:-}"
  log "features: HDF5=${VASP_HDF5} LIBXC=${VASP_LIBXC} WANNIER90=${VASP_WANNIER90} DFTD4=${VASP_DFTD4} OPENMP=${VASP_OPENMP} VTST=${VASP_VTST} WORK_DIR=${WORK_DIR}"
}

# CMake cache wants ';' separators; env uses ':' under MSYS.
cmake_prefix_path_for_cmake() {
  local p="${CMAKE_PREFIX_PATH:-${MINGW_PREFIX}}"
  printf '%s' "${p//:/;}"
}

# Convert Windows / mixed paths to MSYS-style (/c/...) for prefix matching.
to_msys_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    local u
    u="$(cygpath -u "$p" 2>/dev/null || true)"
    if [ -n "$u" ]; then
      printf '%s' "$u"
      return
    fi
  fi
  # C:\foo\bar or C:/foo/bar → /c/foo/bar
  if [[ "$p" =~ ^([A-Za-z]):[/\\](.*)$ ]]; then
    local drive rest
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"
    rest="${BASH_REMATCH[2]//\\//}"
    printf '/%s/%s' "$drive" "$rest"
    return
  fi
  printf '%s' "$p"
}

# True if path is under MINGW_PREFIX, toolchain/install, or a Windows System32 dir.
is_harvestable_dll() {
  local dep="$1"
  local n rn parent
  local tc="${TOOLCHAIN_INSTALL_REAL:-${TOOLCHAIN_DIR}/install}"
  n="$(to_msys_path "$dep")"
  if [ -e "$n" ]; then
    parent="$(cd "$(dirname "$n")" && pwd -P)"
    rn="${parent}/$(basename "$n")"
  else
    rn="$n"
  fi
  case "$n" in
    "${MINGW_PREFIX}"/*|"${MINGW_PREFIX_REAL}"/*) return 0 ;;
    "${tc}"/*|"${TOOLCHAIN_DIR}/install"/*) return 0 ;;
    /[cC]/Windows/System32/*|/[cC]/WINDOWS/system32/*|/[cC]/Windows/system32/*|/[cC]/WINDOWS/System32/*) return 0 ;;
  esac
  case "$rn" in
    "${MINGW_PREFIX}"/*|"${MINGW_PREFIX_REAL}"/*) return 0 ;;
    "${tc}"/*|"${TOOLCHAIN_DIR}/install"/*) return 0 ;;
    /[cC]/Windows/System32/*|/[cC]/WINDOWS/system32/*|/[cC]/Windows/system32/*|/[cC]/WINDOWS/System32/*) return 0 ;;
  esac
  return 1
}

#-----------------------------------------------------------------------------
# [0] preflight — validate inputs and toolchain
#-----------------------------------------------------------------------------
preflight() {
  stage 0 "preflight"
  case "${VASP_GOMP_CRITICAL_WIN32}" in
    ON|OFF) ;;
    *) die "VASP_GOMP_CRITICAL_WIN32 must be ON or OFF" ;;
  esac
  if [ "${MSYSTEM:-}" != "UCRT64" ]; then
    if [ "${ALLOW_NON_UCRT64:-}" = "1" ]; then
      warn "MSYSTEM=${MSYSTEM:-unset} (expected UCRT64); continuing due to ALLOW_NON_UCRT64=1"
    else
      die "MSYSTEM=${MSYSTEM:-unset}; must run in MSYS2 UCRT64 shell (or set ALLOW_NON_UCRT64=1)"
    fi
  fi

  [ -n "${VASP_TARBALL}" ] || die "VASP_TARBALL not set. Usage: VASP_TARBALL=...tar.gz bash $0  (or pass as \$1)"
  # Accept Windows (C:\... / C:/...) or MSYS (/c/...) forms.
  VASP_TARBALL="$(to_msys_path "${VASP_TARBALL}")"
  [ -f "${VASP_TARBALL}" ] || die "tarball not found: ${VASP_TARBALL}"
  [ -d "${VASP_CMAKE_DIR}" ]           || die "vasp_cmake dir not found: ${VASP_CMAKE_DIR}"
  [ -f "${VASP_CMAKE_DIR}/setup.sh" ]  || die "setup.sh missing in ${VASP_CMAKE_DIR}"
  [ -d "${PATCH_DIR}" ] || die "patches dir not found: ${PATCH_DIR}"

  local need=(gfortran gcc cmake ninja patch)
  local soft=(ntldd zip sha256sum)
  local t
  for t in "${need[@]}"; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool '$t' (pacman -S mingw-w64-ucrt-x86_64-... / msys tools)"
  done
  for t in "${soft[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      if [ "${VASP_PIPELINE_MODE}" = "develop" ]; then
        warn "missing tool '$t' (ok for develop; needed for release harvest/zip)"
      else
        die "missing tool '$t' (pacman -S mingw-w64-ucrt-x86_64-... / msys tools)"
      fi
    fi
  done

  resolve_mingw_prefix
  log "MINGW_PREFIX=${MINGW_PREFIX} (real=${MINGW_PREFIX_REAL})"
  log "VASP_PIPELINE_MODE=${VASP_PIPELINE_MODE}"
  log "VASP_VTST=${VASP_VTST} flavor=${FLAVOR}"
  log "WORK_DIR=${WORK_DIR}"
  log "PKG_NAME=${PKG_NAME}"

  # Self-built optional libs (CMAKE_PREFIX_PATH before MINGW_PREFIX)
  source_toolchain_optional

  # key libraries present?
  local lib="${MINGW_PREFIX}/lib"
  [ -f "${lib}/libmsmpi.dll.a" ]    || warn "libmsmpi.dll.a not in ${lib} (msmpi pkg?)"
  ls "${lib}"/libopenblas*.dll.a >/dev/null 2>&1 || warn "OpenBLAS import lib not in ${lib}"
  # fftlib (VASP_FFTLIB=ON) needs POSIX dlopen; MinGW provides it via dlfcn-win32.
  if [ "${VASP_FFTLIB}" = "ON" ]; then
    [ -f "${MINGW_PREFIX}/include/dlfcn.h" ] \
      || die "missing dlfcn.h (pacman -S mingw-w64-ucrt-x86_64-dlfcn) — required for VASP_FFTLIB=ON"
  fi
  log "VASP_FFTLIB=${VASP_FFTLIB}"
  log "VASP_GOMP_CRITICAL_WIN32=${VASP_GOMP_CRITICAL_WIN32}"
  log "toolchain OK (gfortran=$(gfortran -dumpversion), cmake=$(cmake --version | head -1 | awk '{print $3}'))"
  log "tarball: ${VASP_TARBALL}"
}

#-----------------------------------------------------------------------------
# locate_existing_tree — develop mode: find SRC_ROOT/BDIR without wiping WORK_DIR
#-----------------------------------------------------------------------------
locate_existing_tree() {
  stage 1 "locate existing tree (develop; no unpack)"
  [ -d "${WORK_DIR}" ] || die "WORK_DIR missing: ${WORK_DIR} — run a full release build once first"
  SRC_ROOT="$(find "${WORK_DIR}" -maxdepth 2 -type d -name src -printf '%h\n' 2>/dev/null | head -1)"
  [ -n "${SRC_ROOT}" ] || die "no src/ under ${WORK_DIR} — run a full release build once first"
  [ -d "${SRC_ROOT}/src" ] || die "invalid SRC_ROOT: ${SRC_ROOT}"
  BDIR="${SRC_ROOT}/${BUILD_DIR_NAME}"
  log "source root: ${SRC_ROOT}"
  log "build dir:   ${BDIR}"
}

# develop: recompile wrap/planner objects; reconfigure in-place if cache exists
# (does not rm -rf BDIR). Re-pass TOP_LEVEL_INCLUDES so fftlib FFTW remap applies.
develop_prepare() {
  locate_existing_tree
  # Idempotent: apply any new patches (e.g. 0004 MAXMEM) on existing tree
  patch_sources
  inject_vtst_sources
  if [ ! -f "${BDIR}/CMakeCache.txt" ]; then
    warn "no CMake cache at ${BDIR}; running full configure (does not wipe WORK_DIR)"
    # configure() historically rm -rf BDIR — safe here because cache is absent.
    configure
  else
    stage 4 "reuse configure cache (develop; re-apply injects)"
    mkdir -p "${BDIR}"
    compile_msmpi_wrap "${BDIR}"
    local wrap_syms_cm; wrap_syms_cm="$(msmpi_wrap_syms_cmake)"
    local inject_msmpi inject_fftlib inject_mem inject_gomp inject_path
    if command -v cygpath >/dev/null 2>&1; then
      inject_msmpi="$(cygpath -m "${MSMPI_WRAP_INJECT}")"
      inject_fftlib="$(cygpath -m "${FFTLIB_WIN32_INJECT}")"
      inject_mem="$(cygpath -m "${WIN32_MEM_INJECT}")"
      inject_gomp="$(cygpath -m "${GOMP_CRITICAL_WIN32_INJECT}")"
    else
      inject_msmpi="${MSMPI_WRAP_INJECT}"
      inject_fftlib="${FFTLIB_WIN32_INJECT}"
      inject_mem="${WIN32_MEM_INJECT}"
      inject_gomp="${GOMP_CRITICAL_WIN32_INJECT}"
    fi
    inject_path="${inject_msmpi};${inject_fftlib};${inject_mem};${inject_gomp}"
    log "CMAKE_PROJECT_TOP_LEVEL_INCLUDES=${inject_path}"
    log "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
    log "VASP_OPENMP=${VASP_OPENMP} VASP_DFTD4=${VASP_DFTD4} VASP_FFTLIB=${VASP_FFTLIB}"
    # Re-run configure against existing tree so FFTW OMP->threads remap refreshes link lines.
    # Pass the same feature/BLAS knobs as configure() so develop A/B toggles do not
    # drop OpenBLAS / MPI link lines.
    cmake -S "${SRC_ROOT}" -B "${BDIR}" \
      -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
      -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="${inject_path}" \
      -DVASP_MSMPI_WRAP_OBJ="${MSMPI_WRAP_OBJ}" \
      -DVASP_MSMPI_WRAP_SYMS="${wrap_syms_cm}" \
      -DVASP_FFTW_PLANNER_SAFE_OBJ="${FFTW_PLANNER_SAFE_OBJ}" \
      -DVASP_WIN32_MEM_OBJ="${WIN32_MEM_OBJ}" \
      -DVASP_GOMP_CRITICAL_WIN32_OBJ="${GOMP_CRITICAL_WIN32_OBJ}" \
      -DVASP_OPENMP="${VASP_OPENMP}" \
      -DVASP_FFTLIB="${VASP_FFTLIB}" \
      -DVASP_HDF5="${VASP_HDF5}" \
      -DVASP_LIBXC="${VASP_LIBXC}" \
      -DVASP_WANNIER90="${VASP_WANNIER90}" \
      -DVASP_DFTD4="${VASP_DFTD4}" \
      -DBLA_VENDOR=OpenBLAS \
      -DLAPACK_DIR="${MINGW_PREFIX}/lib" \
      -DFFTW_ROOT="${MINGW_PREFIX}" \
      -DMPI_Fortran_INCLUDE_PATH="${MINGW_PREFIX}/include" \
      -DMPI_Fortran_LIBRARIES="${MINGW_PREFIX}/lib/libmsmpi.dll.a"
    log "wrap object ready: ${MSMPI_WRAP_OBJ}"
    log "FFTW planner-safe object: ${FFTW_PLANNER_SAFE_OBJ}"
    log "Win32 MAXMEM object: ${WIN32_MEM_OBJ}"
    log "GOMP FFT planner lock object: ${GOMP_CRITICAL_WIN32_OBJ:-disabled}"
    log "VASP_OPENMP=${VASP_OPENMP}"
    log "VASP_FFTLIB=${VASP_FFTLIB}"
    log "VASP_DFTD4=${VASP_DFTD4}"
  fi
}

#-----------------------------------------------------------------------------
# [1] unpack — extract source into this WORK_DIR stamp only (never wipe siblings)
#-----------------------------------------------------------------------------
unpack() {
  stage 1 "unpack"
  # Clear only the current stamp / override path — do NOT rm -rf all of build_work/.
  if [ -e "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
  fi
  mkdir -p "${WORK_DIR}"
  log "extracting ${VASP_TARBALL} into ${WORK_DIR} ..."
  # On Windows, relative symlinks under testsuite/POTCARS often fail and make
  # GNU tar exit non-zero. Keep going if src/ is present; optionally materialize
  # those POTCAR links as real file copies (default ON) so the testsuite can run.
  set +e
  tar -xf "${VASP_TARBALL}" -C "${WORK_DIR}"
  local tar_rc=$?
  set -e
  if [ "${tar_rc}" -ne 0 ]; then
    warn "tar exited ${tar_rc} (often Windows symlink failures under testsuite/POTCARS); continuing if src/ exists"
  fi
  materialize_potcar_links

  # locate the source root = directory containing src/
  SRC_ROOT="$(find "${WORK_DIR}" -maxdepth 2 -type d -name src -printf '%h\n' | head -1)"
  [ -n "${SRC_ROOT}" ] || die "could not find a 'src/' dir in the tarball"
  # setup.sh expects testsuite/ to exist even if POTCAR symlinks were skipped
  mkdir -p "${SRC_ROOT}/testsuite"
  log "source root: ${SRC_ROOT}"

  # stage the CMake port at <root>/cmake/ (overwrite if present)
  rm -rf "${SRC_ROOT}/cmake"
  cp -a "${VASP_CMAKE_DIR}" "${SRC_ROOT}/cmake"
  log "staged vasp_cmake -> ${SRC_ROOT}/cmake"

  # Overlays (FindDFTD4 / FindLibXC) into staged cmake/ — do not edit submodule.
  if [ -d "${CMAKE_OVERLAY_DIR}" ]; then
    local ov
    for ov in "${CMAKE_OVERLAY_DIR}"/*.cmake; do
      [ -f "${ov}" ] || continue
      cp -f "${ov}" "${SRC_ROOT}/cmake/$(basename "${ov}")"
      log "  overlay: $(basename "${ov}")"
    done
  fi

  # Enable DFTD4 via staged CMakeLists_root.txt (before setup materializes root).
  local p3="${PATCH_DIR}/0003-cmake-enable-dftd4.patch"
  local root_lists="${SRC_ROOT}/cmake/CMakeLists/CMakeLists_root.txt"
  if [ -f "${p3}" ] && [ -f "${root_lists}" ]; then
    if grep -q 'find_package(DFTD4 MODULE REQUIRED)' "${root_lists}" 2>/dev/null; then
      log "already patched: CMakeLists_root.txt (DFTD4)"
    elif patch --dry-run --forward -p1 -d "${SRC_ROOT}" < "${p3}" >/dev/null 2>&1; then
      patch --forward -p1 -d "${SRC_ROOT}" < "${p3}" && log "applied $(basename "${p3}")"
    else
      die "failed to apply $(basename "${p3}") to staged cmake/"
    fi
  else
    warn "0003 DFTD4 patch or CMakeLists_root.txt missing; VASP_DFTD4 may fail"
  fi
}

#-----------------------------------------------------------------------------
# [2] setup — create the 9 CMakeLists.txt symlinks via the official setup.sh
#-----------------------------------------------------------------------------
setup() {
  stage 2 "setup (CMakeLists symlinks)"
  ( cd "${SRC_ROOT}" && bash cmake/setup.sh "${SRC_ROOT}" )
  # Windows CMake (MinGW) does not follow MSYS symlink/junction reparse points.
  # Materialize CMakeLists.txt as real files so configure can proceed.
  local link target dir
  while IFS= read -r -d "" link; do
    dir="$(dirname "${link}")"
    target="$(readlink "${link}")"
    rm -f "${link}"
    cp -f "${dir}/${target}" "${link}"
  done < <(find "${SRC_ROOT}" -name CMakeLists.txt -type l -print0)
  [ -f "${SRC_ROOT}/CMakeLists.txt" ] || die "CMakeLists.txt missing after materialize"
  log "materialized CMakeLists.txt files for Windows CMake"
}

#-----------------------------------------------------------------------------
# [3] patch — apply Win32 timing + MAXMEM + BSE AVpW guards (idempotent)
#-----------------------------------------------------------------------------
patch_sources() {
  stage 3 "patch (dclock_/timing_ Win32 + AUTOSET MAXMEM + BSE AVpW/IBSE)"
  # explicit file -> patch mapping (robust; no name guessing)
  # marker: substring already present => skip (idempotent)
  local entries=(
    "src/lib/dclock_.c|${PATCH_DIR}/0001-dclock_-win32-getrusage.patch|win32_filetime_to_sec"
    "src/lib/timing_.c|${PATCH_DIR}/0002-timing_-win32-getrusage.patch|win32_filetime_to_sec"
    "src/ini.F|${PATCH_DIR}/0004-autoset-available-memory-win32.patch|vasp_win32_available_memory_kb"
    "src/bse.F|${PATCH_DIR}/0005-bse-guard-avpw-zeroing.patch|IF (ALLOCATED(AVpW)) AVpW=0"
    "src/bse.F|${PATCH_DIR}/0006-bse-lqp-force-ibse0.patch|QPBSE/LQP: forcing IBSE=0"
  )
  # Unified diffs (diff -u / git diff). Use -l (ignore whitespace) so Fortran
  # indent/spacing drift does not break apply; still idempotent via markers.
  local patch_flags=(--forward -l -p1)
  local entry f p marker rest
  for entry in "${entries[@]}"; do
    f="${entry%%|*}"; rest="${entry#*|}"
    p="${rest%%|*}"; marker="${rest#*|}"
    [ -f "$p" ] || { warn "patch missing: $p"; continue; }
    if grep -q "${marker}" "${SRC_ROOT}/${f}" 2>/dev/null; then
      log "already patched: $f"; continue
    fi
    if patch --dry-run "${patch_flags[@]}" -d "${SRC_ROOT}" < "$p" >/dev/null 2>&1; then
      patch "${patch_flags[@]}" -d "${SRC_ROOT}" < "$p" && log "applied $(basename "$p") -> $f"
    else
      warn "patch not clean (maybe applied): $(basename "$p")"
      # Show reject hint once for triage (still non-fatal until marker check)
      patch --dry-run "${patch_flags[@]}" -d "${SRC_ROOT}" < "$p" 2>&1 | tail -n 20 || true
    fi
  done
  grep -q "win32_filetime_to_sec" "${SRC_ROOT}/src/lib/dclock_.c" || die "dclock_.c patch not active"
  grep -q "win32_filetime_to_sec" "${SRC_ROOT}/src/lib/timing_.c" || die "timing_.c patch not active"
  grep -q "vasp_win32_available_memory_kb" "${SRC_ROOT}/src/ini.F" || die "ini.F Win32 MAXMEM patch not active"
  grep -q "IF (ALLOCATED(AVpW)) AVpW=0" "${SRC_ROOT}/src/bse.F" || die "bse.F AVpW ALLOCATED guard patch not active"
  grep -q "QPBSE/LQP: forcing IBSE=0" "${SRC_ROOT}/src/bse.F" || die "bse.F LQP IBSE=0 force patch not active"
}

#-----------------------------------------------------------------------------
# MPI_IN_PLACE --wrap shim (gfortran + MS-MPI sentinel mismatch)
# See shim/msmpi_inplace_wrap.c and docs/MSYS2_MSMPI_MULTIRANK.md
#
# IMPORTANT: do NOT put --wrap / wrap.o into CMAKE_EXE_LINKER_FLAGS — that
# breaks CMake's Fortran try_compile. Inject per-target via
# CMAKE_PROJECT_TOP_LEVEL_INCLUDES + shim/cmake_msmpi_wrap_inject.cmake.
#-----------------------------------------------------------------------------
MSMPI_WRAP_SRC="${MSMPI_WRAP_SRC:-${SCRIPT_DIR}/shim/msmpi_inplace_wrap.c}"
MSMPI_WRAP_INJECT="${MSMPI_WRAP_INJECT:-${SCRIPT_DIR}/shim/cmake_msmpi_wrap_inject.cmake}"
FFTLIB_WIN32_INJECT="${FFTLIB_WIN32_INJECT:-${SCRIPT_DIR}/shim/cmake_fftlib_win32_inject.cmake}"
FFTW_PLANNER_SAFE_SRC="${FFTW_PLANNER_SAFE_SRC:-${SCRIPT_DIR}/shim/fftw_planner_thread_safe.c}"
WIN32_MEM_SRC="${WIN32_MEM_SRC:-${SCRIPT_DIR}/shim/win32_available_memory.c}"
WIN32_MEM_INJECT="${WIN32_MEM_INJECT:-${SCRIPT_DIR}/shim/cmake_win32_mem_inject.cmake}"
GOMP_CRITICAL_WIN32_SRC="${GOMP_CRITICAL_WIN32_SRC:-${SCRIPT_DIR}/shim/gomp_critical_win32.c}"
GOMP_CRITICAL_WIN32_INJECT="${GOMP_CRITICAL_WIN32_INJECT:-${SCRIPT_DIR}/shim/cmake_gomp_critical_win32_inject.cmake}"
# Symbols discovered via nm on vasp_std (collectives / RMA that may see IN_PLACE or BOTTOM)
# Also wrap BLACS grid init/map: optional TopsRepeat (default off; opt in via
# MSMPI_BLACS_TOPSREPEAT=1). See docs/MSMPI_INPLACE_SHIM.md.
MSMPI_WRAP_SYMS="${MSMPI_WRAP_SYMS:-mpi_allreduce_ mpi_reduce_ mpi_allgather_ mpi_allgatherv_ mpi_gather_ mpi_alltoall_ mpi_alltoallv_ mpi_iallgather_ mpi_bcast_ mpi_waitall_ mpi_get_ blacs_gridinit_ blacs_gridmap_}"

msmpi_wrap_syms_cmake() { # semicolon-separated list for CMake cache
  local s out=""
  for s in ${MSMPI_WRAP_SYMS}; do
    if [ -z "${out}" ]; then out="${s}"; else out="${out};${s}"; fi
  done
  printf '%s' "${out}"
}

# to_mixed_path <unix-path> — Ninja/cmd.exe prefers Windows mixed paths
to_mixed_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

compile_msmpi_wrap() { # compile_msmpi_wrap <outdir> -> sets MSMPI_WRAP_OBJ (+ FFTW + Win32 mem objs)
  local outdir="$1"
  mkdir -p "${outdir}"
  local obj_unix="${outdir}/msmpi_inplace_wrap.o"
  local fftw_obj_unix="${outdir}/fftw_planner_thread_safe.o"
  local mem_obj_unix="${outdir}/win32_available_memory.o"
  local gomp_obj_unix="${outdir}/gomp_critical_win32.o"
  [ -f "${MSMPI_WRAP_SRC}" ] || die "missing MS-MPI wrap shim: ${MSMPI_WRAP_SRC}"
  [ -f "${MSMPI_WRAP_INJECT}" ] || die "missing MS-MPI wrap CMake inject: ${MSMPI_WRAP_INJECT}"
  [ -f "${FFTLIB_WIN32_INJECT}" ] || die "missing fftlib win32 CMake inject: ${FFTLIB_WIN32_INJECT}"
  [ -f "${FFTW_PLANNER_SAFE_SRC}" ] || die "missing FFTW planner-safe shim: ${FFTW_PLANNER_SAFE_SRC}"
  [ -f "${WIN32_MEM_SRC}" ] || die "missing Win32 MAXMEM shim: ${WIN32_MEM_SRC}"
  [ -f "${WIN32_MEM_INJECT}" ] || die "missing Win32 MAXMEM CMake inject: ${WIN32_MEM_INJECT}"
  [ -f "${GOMP_CRITICAL_WIN32_SRC}" ] || die "missing GOMP Win32 lock shim: ${GOMP_CRITICAL_WIN32_SRC}"
  [ -f "${GOMP_CRITICAL_WIN32_INJECT}" ] || die "missing GOMP Win32 lock CMake inject: ${GOMP_CRITICAL_WIN32_INJECT}"
  gcc -c "${MSMPI_WRAP_SRC}" -I"${MINGW_PREFIX}/include" -o "${obj_unix}"
  # Planner-safe ctor needs libfftw3_threads; skip when VASP_OPENMP=OFF.
  if [ "${VASP_OPENMP}" != "OFF" ]; then
    gcc -c "${FFTW_PLANNER_SAFE_SRC}" -I"${MINGW_PREFIX}/include" -o "${fftw_obj_unix}"
    FFTW_PLANNER_SAFE_OBJ="$(to_mixed_path "${fftw_obj_unix}")"
    log "compiled FFTW planner-safe ctor: ${FFTW_PLANNER_SAFE_OBJ}"
  else
    FFTW_PLANNER_SAFE_OBJ=""
    log "skipped FFTW planner-safe ctor (VASP_OPENMP=OFF)"
  fi
  gcc -c "${WIN32_MEM_SRC}" -o "${mem_obj_unix}"
  if [ "${VASP_OPENMP}" = "ON" ] && [ "${VASP_GOMP_CRITICAL_WIN32}" = "ON" ]; then
    gcc -c "${GOMP_CRITICAL_WIN32_SRC}" -o "${gomp_obj_unix}"
    GOMP_CRITICAL_WIN32_OBJ="$(to_mixed_path "${gomp_obj_unix}")"
    log "compiled GOMP FFT planner Win32 lock: ${GOMP_CRITICAL_WIN32_OBJ}"
  else
    GOMP_CRITICAL_WIN32_OBJ=""
    log "skipped GOMP FFT planner Win32 lock"
  fi
  MSMPI_WRAP_OBJ="$(to_mixed_path "${obj_unix}")"
  WIN32_MEM_OBJ="$(to_mixed_path "${mem_obj_unix}")"
  log "compiled MS-MPI IN_PLACE wrap: ${MSMPI_WRAP_OBJ}"
  log "compiled Win32 available-memory helper: ${WIN32_MEM_OBJ}"
}

#-----------------------------------------------------------------------------
# [4] configure — cmake (Ninja)
#-----------------------------------------------------------------------------
configure() {
  stage 4 "configure (cmake)"
  BDIR="${SRC_ROOT}/${BUILD_DIR_NAME}"
  rm -rf "${BDIR}"
  mkdir -p "${BDIR}"
  local jobs; jobs="$(compute_jobs)"
  compile_msmpi_wrap "${BDIR}"
  local wrap_syms_cm; wrap_syms_cm="$(msmpi_wrap_syms_cmake)"
  local inject_msmpi inject_fftlib inject_mem inject_gomp inject_path
  if command -v cygpath >/dev/null 2>&1; then
    inject_msmpi="$(cygpath -m "${MSMPI_WRAP_INJECT}")"
    inject_fftlib="$(cygpath -m "${FFTLIB_WIN32_INJECT}")"
    inject_mem="$(cygpath -m "${WIN32_MEM_INJECT}")"
    inject_gomp="$(cygpath -m "${GOMP_CRITICAL_WIN32_INJECT}")"
  else
    inject_msmpi="${MSMPI_WRAP_INJECT}"
    inject_fftlib="${FFTLIB_WIN32_INJECT}"
    inject_mem="${WIN32_MEM_INJECT}"
    inject_gomp="${GOMP_CRITICAL_WIN32_INJECT}"
  fi
  # Semicolon list: MS-MPI wrap + fftlib + MAXMEM + GOMP named-critical helper
  inject_path="${inject_msmpi};${inject_fftlib};${inject_mem};${inject_gomp}"
  # Re-apply optional env in case configure is invoked alone.
  source_toolchain_optional
  local cmake_prefix
  cmake_prefix="$(cmake_prefix_path_for_cmake)"
  log "MS-MPI wrap symbols: ${wrap_syms_cm}"
  log "CMAKE_PROJECT_TOP_LEVEL_INCLUDES=${inject_path}"
  log "CMAKE_PREFIX_PATH (cmake)=${cmake_prefix}"
  log "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
  log "VASP_OPENMP=${VASP_OPENMP}"
  cmake -S "${SRC_ROOT}" -B "${BDIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DCMAKE_Fortran_COMPILER=gfortran \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_PREFIX_PATH="${cmake_prefix}" \
    -DVASP_OPENMP="${VASP_OPENMP}" \
    -DVASP_FFTLIB="${VASP_FFTLIB}" \
    -DVASP_HDF5="${VASP_HDF5}" \
    -DVASP_LIBXC="${VASP_LIBXC}" \
    -DVASP_WANNIER90="${VASP_WANNIER90}" \
    -DVASP_DFTD4="${VASP_DFTD4}" \
    -DVASP_SCALAPACK=ON \
    -DVASP_SHMEM=OFF \
    -DVASP_SYSV=OFF \
    -DVASP_TARGET_CPU="${TARGET_CPU}" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--stack,268435456 -ldl" \
    -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="${inject_path}" \
    -DVASP_MSMPI_WRAP_OBJ="${MSMPI_WRAP_OBJ}" \
    -DVASP_MSMPI_WRAP_SYMS="${wrap_syms_cm}" \
    -DVASP_FFTW_PLANNER_SAFE_OBJ="${FFTW_PLANNER_SAFE_OBJ}" \
    -DVASP_WIN32_MEM_OBJ="${WIN32_MEM_OBJ}" \
    -DVASP_GOMP_CRITICAL_WIN32_OBJ="${GOMP_CRITICAL_WIN32_OBJ}" \
    -DBLA_VENDOR=OpenBLAS \
    -DLAPACK_DIR="${MINGW_PREFIX}/lib" \
    -DFFTW_ROOT="${MINGW_PREFIX}" \
    -DMPI_Fortran_INCLUDE_PATH="${MINGW_PREFIX}/include" \
    -DMPI_Fortran_LIBRARIES="${MINGW_PREFIX}/lib/libmsmpi.dll.a"
  log "configure done; will build with -j${jobs}"
}

#-----------------------------------------------------------------------------
# [5] build — ninja (RAM-capped)
#-----------------------------------------------------------------------------
build() {
  stage 5 "build (ninja)"
  local jobs; jobs="$(compute_jobs)"
  cmake --build "${BDIR}" -j "${jobs}"
  log "built variants:" "${BUILD_VARIANTS}"
}

#-----------------------------------------------------------------------------
# [6] harvest — collect exe + all runtime DLLs + MS-MPI launcher
#-----------------------------------------------------------------------------
# Print the DLL dependency path for an exe (one per line, recursive).
dll_deps() { # dll_deps <exe>
  local exe="$1"
  if command -v ntldd >/dev/null 2>&1; then
    ntldd -R "$exe" 2>/dev/null | awk '/=>/ {print $3}' | sort -u
  else
    ldd "$exe" 2>/dev/null | awk '/=>/ {print $3}' | sort -u
  fi
}

harvest() {
  stage 6 "harvest (DLLs + MS-MPI)"
  resolve_mingw_prefix
  PKG_DIR="${WORK_DIR}/${PKG_NAME}"
  rm -rf "${PKG_DIR}"; mkdir -p "${PKG_DIR}/bin"

  # 1) the built executables (CMake installs under build/bin/ by default)
  local v exe src_exe
  for v in ${BUILD_VARIANTS}; do
    src_exe="$(ls "${BDIR}/bin/${v}.exe" "${BDIR}/${v}.exe" 2>/dev/null | head -1 || true)"
    [ -n "${src_exe}" ] || { warn "${v}.exe not found, skip"; continue; }
    cp -f "${src_exe}" "${PKG_DIR}/bin/${v}.exe"
    log "  + ${v}.exe"
  done

  # 2) recursively-collected DLLs (under real MINGW_PREFIX or System32)
  local dep dll
  declare -A seen=()
  for exe in "${PKG_DIR}/bin"/*.exe; do
    [ -f "$exe" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ -f "$dep" ] || continue
      is_harvestable_dll "$dep" || continue
      dll="$(basename "$dep")"
      [ -n "${seen[$dll]:-}" ] && continue
      seen[$dll]=1
      cp -f "$dep" "${PKG_DIR}/bin/${dll}"
    done < <(dll_deps "$exe")
  done

  # 3) MS-MPI launcher (mpiexec/smpd) — required for portable multi-core launch.
  # Prefer official Microsoft MPI (Program Files) over PATH/Scoop redistributable.
  # winget Microsoft.msmpi puts mpiexec/smpd in Bin, msmpi.dll/msmpires.dll in System32.
  local mpibin mpiexec_bin mpiexec_dir=""
  mpiexec_bin="$(command -v mpiexec 2>/dev/null || true)"
  [ -n "${mpiexec_bin}" ] && mpiexec_dir="$(dirname "${mpiexec_bin}")"
  mpibin="$(first_existing \
      "${MSMPI_BIN:-EMPTY}" \
      "/c/Program Files/Microsoft MPI/Bin" \
      "/c/Program Files (x86)/Microsoft MPI/Bin" \
      "${mpiexec_dir:-EMPTY}" \
      "${HOME}/scoop/apps/msmpi/current" \
      "${MINGW_PREFIX}/bin" || true)"
  # Scoop "current" is a symlink; plain find -P does not list its children.
  if [ -n "${mpibin}" ] && [ -d "${mpibin}" ]; then
    mpibin="$(cd "${mpibin}" && pwd -P)"
  fi
  local m f sys32="/c/Windows/System32"
  for m in mpiexec.exe smpd.exe msmpi.dll msmpires.dll; do
    f="${mpibin}/${m}"
    if [ ! -f "$f" ] && [ -f "${sys32}/${m}" ]; then
      f="${sys32}/${m}"
    fi
    if [ -f "$f" ]; then
      cp -f "$f" "${PKG_DIR}/bin/$m" && log "  + $m"
    else
      warn "MS-MPI file not found for harvest: $m (set MSMPI_BIN or install Microsoft.msmpi)"
    fi
  done

  # FFTW: ship pthread backend only. Upstream fftlib may dlopen libfftw3_omp*;
  # a real omp DLL pulls libgomp into planning. Exe is remapped to
  # libfftw3_threads via shim/cmake_fftlib_win32_inject.cmake.
  local threads_dll="${MINGW_PREFIX}/bin/libfftw3_threads-3.dll"
  if [ -f "${threads_dll}" ]; then
    cp -f "${threads_dll}" "${PKG_DIR}/bin/libfftw3_threads-3.dll"
    log "  + libfftw3_threads-3.dll (FFTW pthread backend)"
  else
    warn "libfftw3_threads-3.dll not found under ${MINGW_PREFIX}/bin"
  fi
  if [ -f "${PKG_DIR}/bin/libfftw3_omp-3.dll" ] || [ -f "${PKG_DIR}/bin/libfftw3_omp.dll" ]; then
    rm -f "${PKG_DIR}/bin/libfftw3_omp-3.dll" "${PKG_DIR}/bin/libfftw3_omp.dll"
    log "  - removed libfftw3_omp*.dll from package (use threads backend)"
  fi

  # Hard gate: portable ZIP must never ship AWS/S3 HDF5 deps (libaws*).
  local aws_hits
  aws_hits="$(find "${PKG_DIR}" -iname 'libaws*' 2>/dev/null | head -20 || true)"
  if [ -n "${aws_hits}" ]; then
    printf '%s\n' "${aws_hits}" >&2
    die "libaws* found under ${PKG_DIR} — refuse to package (use self-built HDF5 with ROS3 off)"
  fi

  log "harvested $(ls "${PKG_DIR}/bin" | wc -l) files (libaws check OK)"
}

#-----------------------------------------------------------------------------
# [7] package — run.bat + assemble + zip
#-----------------------------------------------------------------------------
# True for Windows API-set / OneCore forwarders that ntldd often reports
# as "not found" even though the OS resolves them at runtime.
is_windows_api_set_stub() {
  local base
  base="$(basename "$1" | tr 'A-Z' 'a-z')"
  case "$base" in
    api-ms-*.dll|ext-ms-*.dll) return 0 ;;
  esac
  return 1
}

# True if a missing dependency looks like a MinGW/runtime DLL we should bundle.
# Ignores OS-only optional modules (AzureAttest*, PdmUtilities, etc.).
is_bundlable_runtime_dll() {
  local base
  base="$(basename "$1" | tr 'A-Z' 'a-z')"
  case "$base" in
    lib*.dll|msmpi.dll|msmpires.dll|msmpi*.dll) return 0 ;;
  esac
  return 1
}

# Collect "not found" deps that are real bundlable runtimes (not API-set stubs).
collect_unresolved_bundlable_dlls() { # <exe>
  local exe="$1" line name
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*not found.*//I')"
    [ -n "$name" ] || continue
    is_windows_api_set_stub "$name" && continue
    is_bundlable_runtime_dll "$name" || continue
    printf '%s\n' "$line"
  done < <(ntldd -R "$exe" 2>/dev/null | grep -i 'not found' || true)
}


emit_run_bat() { # emit_run_bat <outfile>
  cat > "$1" <<'BATCH'
@echo off
REM Keep caller's CWD (job directory with INCAR/POSCAR/...). Do NOT cd to %~dp0.
set "VASP_HOME=%~dp0"
set "PATH=%VASP_HOME%bin;%PATH%"
REM OpenBLAS (MSYS2) is OpenMP-threaded; under mpiexec -n N each rank must use
REM a single BLAS thread, otherwise cores are oversubscribed and OpenBLAS's
REM buffer allocator can fail. Pin both vars (OMP_NUM_THREADS is authoritative).
REM Pass -env so ranks get the pins even if the parent env is cleared.
set OMP_NUM_THREADS=1
set OPENBLAS_NUM_THREADS=1
REM Multi-rank MS-MPI requires the MPI_IN_PLACE --wrap shim linked at build
REM time (shim/msmpi_inplace_wrap.c). See docs/MSYS2_MSMPI_MULTIRANK.md.
REM Optional: set MSMPI_WRAP_DEBUG=1 to log sentinel rewrites.
if not exist "INCAR" (
  echo [run.bat] ERROR: no INCAR in current directory.
  echo [run.bat] cd to your job folder ^(with INCAR/POSCAR/POTCAR/KPOINTS^), then call this script.
  echo [run.bat] VASP_HOME=%VASP_HOME%
  exit /b 1
)
echo Starting VASP on 4 cores...
"%VASP_HOME%bin\mpiexec.exe" -n 4 -env OMP_NUM_THREADS 1 -env OPENBLAS_NUM_THREADS 1 -env OMP_DYNAMIC FALSE -env OMP_MAX_ACTIVE_LEVELS 1 "%VASP_HOME%bin\vasp_std.exe"
pause
BATCH
}

package() {
  stage 7 "package (run.bat + zip)"

  # hard gates: required executables must be present
  local v
  for v in ${BUILD_VARIANTS}; do
    [ -f "${PKG_DIR}/bin/${v}.exe" ] || die "missing ${v}.exe in package (harvest failed?)"
  done
  [ -f "${PKG_DIR}/bin/mpiexec.exe" ] || die "missing mpiexec.exe in package (install Microsoft MPI runtime?)"

  emit_run_bat "${PKG_DIR}/run.bat"

  # Fail only on missing MinGW/runtime DLLs we expect to ship. Windows API-set
  # forwarders (api-ms-*, ext-ms-*) and unrelated OS stubs must not fail packaging.
  local exe unresolved=0 missing
  for exe in "${PKG_DIR}/bin"/vasp_*.exe; do
    [ -f "$exe" ] || continue
    missing="$(collect_unresolved_bundlable_dlls "$exe")"
    if [ -n "$missing" ]; then
      unresolved=1
      warn "unresolved bundlable DLL(s) for $(basename "$exe"):"
      printf '%s\n' "$missing" >&2
    fi
  done
  [ "$unresolved" -eq 0 ] || die "ntldd reported missing MinGW/runtime DLLs — package is not self-contained"

  # Write via temp name then replace — avoids "Device or resource busy" when an
  # Explorer/antivirus handle still holds the previous *.zip.
  local zip_out="${SCRIPT_DIR}/${PKG_NAME}.zip"
  local zip_tmp="${SCRIPT_DIR}/${PKG_NAME}.zip.partial"
  rm -f "${zip_tmp}"
  ( cd "${WORK_DIR}" && zip -qr "${zip_tmp}" "${PKG_NAME}" ) || die "zip failed"
  if rm -f "${zip_out}" 2>/dev/null && mv -f "${zip_tmp}" "${zip_out}"; then
    :
  else
    # Destination locked: keep a usable alternate artifact and continue.
    local zip_alt="${SCRIPT_DIR}/${PKG_NAME}-new.zip"
    rm -f "${zip_alt}"
    mv -f "${zip_tmp}" "${zip_alt}" || die "zip wrote but could not move ${zip_tmp}"
    zip_out="${zip_alt}"
    warn "could not replace ${PKG_NAME}.zip (locked); wrote ${zip_out}"
  fi
  ( cd "${SCRIPT_DIR}" && sha256sum "$(basename "${zip_out}")" > "${zip_out}.sha256" )
  log "artifact: ${zip_out}"
  cat "${zip_out}.sha256"
}

#-----------------------------------------------------------------------------
# main
#-----------------------------------------------------------------------------
main() {
  parse_args "$@"
  resolve_flavor_and_work_dir
  log "VASP Windows-native build (MSYS2 UCRT64, route C2)"
  log "mode: ${VASP_PIPELINE_MODE}"
  preflight

  if [ "${VASP_PIPELINE_MODE}" = "develop" ]; then
    # Never unpack (would wipe this WORK_DIR stamp). Reuse tree; stop after build.
    develop_prepare
    build
    local v exe
    log "develop build outputs (copy into an existing portable bin/ for testsuite):"
    local pkg_bin="${WORK_DIR}/${PKG_NAME}/bin"
    for v in ${BUILD_VARIANTS}; do
      exe="$(ls "${BDIR}/bin/${v}.exe" "${BDIR}/${v}.exe" 2>/dev/null | head -1 || true)"
      if [ -n "${exe}" ]; then
        log "  ${exe}"
        if [ -d "${pkg_bin}" ]; then
          cp -f "${exe}" "${pkg_bin}/"
          log "  -> ${pkg_bin}/$(basename "${exe}")"
        fi
      else
        warn "  ${v}.exe not found under ${BDIR}"
      fi
    done
    if [ -d "${pkg_bin}" ]; then
      if [ -f "${MINGW_PREFIX}/bin/libfftw3_threads-3.dll" ]; then
        cp -f "${MINGW_PREFIX}/bin/libfftw3_threads-3.dll" "${pkg_bin}/"
      fi
      rm -f "${pkg_bin}/libfftw3_omp-3.dll" "${pkg_bin}/libfftw3_omp.dll"
      log "portable bin refreshed (FFTW threads; omp DLL removed): ${pkg_bin}"
    fi
    log "BDIR=${BDIR}"
    log "PKG_DIR hint (if previously harvested): ${WORK_DIR}/${PKG_NAME}"
    log "DONE (develop) — skipped harvest/package/zip"
    return 0
  fi

  unpack
  setup
  patch_sources
  inject_vtst_sources
  configure
  build
  harvest
  package
  write_flavor_current
  log "DONE — green portable ZIP at ${SCRIPT_DIR}/${PKG_NAME}.zip"
}

main "$@"
