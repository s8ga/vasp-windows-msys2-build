#!/usr/bin/env bash
# =============================================================================
# run_testsuite.sh — run VASP testsuite against a portable MSYS2/MS-MPI build
#
# UCRT64 shell:
#   bash toolchain/run_testsuite.sh              # FAST category (default overlay)
#   bash toolchain/run_testsuite.sh --all        # full suite
#   MODE=all bash toolchain/run_testsuite.sh
#   # Single / few recipes (official: VASP_TESTSUITE_TESTS) — NOT a positional
#   # arg to upstream ./runtest. This wrapper accepts names for convenience:
#   bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT
#   VASP_TESTSUITE_TESTS='bulk_GaAs_ACFDT bulk_BN_PBE0' bash toolchain/run_testsuite.sh
#   TESTSUITE_ROOT=/c/path/to/vasp.6.6.0/testsuite \
#     VASP_PORTABLE_BIN=/c/path/to/vasp-*-msys2-portable/bin \
#     bash toolchain/run_testsuite.sh
#   # Flavor (generic): VASP_BUILD_FLAVOR / FLAVOR, or convenience VASP_VTST=ON → vtst
#   # Resolve order: env_ucrt64 (+ local.env) → flavor/PKG_NAME → paths
#   VASP_BUILD_FLAVOR=vtst bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT
#   VASP_VTST=ON bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT
#   # Resolve-only smoke (print paths, exit 0; no compare tool / runtest):
#   TESTSUITE_RESOLVE_ONLY=1 bash toolchain/run_testsuite.sh
#
# Upstream ./runtest CLI is only: [-f|--fast|-a|--all] [config-file]
# Recipe selection is via VASP_TESTSUITE_TESTS (see vasp.at wiki Validation_tests).
# Extra names after --fast/--all here are exported as VASP_TESTSUITE_TESTS.
#
# This repo does NOT ship the licensed testsuite/. The runner:
#   0) Sources env_ucrt64.sh (→ local.env) before resolving flavor
#   1) Locates extracted testsuite with runtest (flavor-aware via CURRENT):
#        TESTSUITE_ROOT > SRC_ROOT/testsuite >
#        build_work/<flavor>/CURRENT stamp > WORK_DIR > flavor stamps
#      (repo-root /testsuite is inspection-only — never used to run)
#   2) Locates portable bin/ (exact flavor package only; no cross-flavor fallback)
#   3) Copies testsuite_overlays/msys2_msmpi_{fast,all}.conf into that directory
#   4) Builds compare_numbertable_new into testsuite/tools/ (ephemeral)
#   5) Sets thread env + PATH, then runs ./runtest <overlay.conf> only
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '\033[1;34m[testsuite]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

to_msys_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p" | sed -e 's#^\([A-Za-z]\):#/\L\1#' -e 's#\\#/#g'
  fi
}

#-----------------------------------------------------------------------------
# Env first (env_ucrt64 → local.env), then flavor / PKG_NAME, then paths.
# Already-exported CLI vars win over local.env when local.env uses
#   export FOO="${FOO:-value}"  (see local.env.example). Plain `export FOO=x`
# overwrites. Do not use set -a here — env_ucrt64 owns MSMPI/PATH setup.
#-----------------------------------------------------------------------------
if [ -f "${SCRIPT_DIR}/env_ucrt64.sh" ] && [ "${SKIP_ENV_UCRT64:-}" != "1" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/env_ucrt64.sh" || warn "env_ucrt64.sh returned non-zero; continuing"
fi

OVERLAY_DIR="${TESTSUITE_OVERLAY_DIR:-${REPO_ROOT}/testsuite_overlays}"
BUILD_WORK_ROOT="${BUILD_WORK_ROOT:-${REPO_ROOT}/build_work}"
WORK_DIR="${WORK_DIR:-${BUILD_WORK_ROOT}}"

#-----------------------------------------------------------------------------
# Generic flavor (after env so local.env knobs apply)
#   Primary: VASP_BUILD_FLAVOR (default stock) → build_work/<flavor>/CURRENT
#   Convenience: VASP_VTST=ON|OFF when flavor unset → vtst|stock
#   Portable dirs: stock → …-msys2-portable ; else → …-msys2-portable-<flavor>
#   Exact match only — never silently adopt a different …-portable* package.
#   New flavors: create build_work/<name>/CURRENT + matching package name suffix.
#-----------------------------------------------------------------------------
FLAVOR_EXPLICIT=0
VASP_VTST="${VASP_VTST:-OFF}"
case "${VASP_VTST}" in
  ON|OFF) ;;
  *) die "VASP_VTST must be ON or OFF (got '${VASP_VTST}'); or set VASP_BUILD_FLAVOR=<name>" ;;
esac

if [ -n "${VASP_BUILD_FLAVOR:-}" ]; then
  FLAVOR="${VASP_BUILD_FLAVOR}"
  FLAVOR_EXPLICIT=1
elif [ -n "${FLAVOR:-}" ]; then
  # Already exported (e.g. from pipeline / local.env)
  FLAVOR_EXPLICIT=1
elif [ "${VASP_VTST}" = "ON" ]; then
  FLAVOR="vtst"
  FLAVOR_EXPLICIT=1
else
  FLAVOR="stock"
fi

case "${FLAVOR}" in
  ''|*[!a-zA-Z0-9_-]*)
    die "invalid flavor '${FLAVOR}' (use [A-Za-z0-9_-]+ via VASP_BUILD_FLAVOR)"
    ;;
esac

# VASP_VTST=ON always implies vtst; conflict with a different explicit flavor.
if [ "${VASP_VTST}" = "ON" ] && [ "${FLAVOR}" != "vtst" ]; then
  die "conflict: VASP_BUILD_FLAVOR/FLAVOR=${FLAVOR} but VASP_VTST=ON (implies vtst).
  Unset VASP_VTST, or set VASP_BUILD_FLAVOR=vtst."
fi

export VASP_BUILD_FLAVOR="${FLAVOR}"
export FLAVOR

# Optional PKG_NAME override (pipeline-style); else derived from flavor convention.
PKG_NAME="${PKG_NAME:-}"
if [ -z "${PKG_NAME}" ]; then
  if [ "${FLAVOR}" = "stock" ]; then
    PKG_NAME="vasp-6.6.0-msys2-portable"
  else
    PKG_NAME="vasp-6.6.0-msys2-portable-${FLAVOR}"
  fi
fi

bin_has_vasp() {
  local b="$1"
  [ -f "${b}/vasp_std.exe" ]
}

# Basename of a portable package dir matches this flavor?
# stock: ends with -msys2-portable (no further -<flavor> suffix)
# other: ends with -msys2-portable-<flavor>
pkg_basename_matches_flavor() {
  local base="$1"
  if [ "${FLAVOR}" = "stock" ]; then
    case "${base}" in
      *-msys2-portable) return 0 ;;
      *) return 1 ;;
    esac
  else
    case "${base}" in
      *-msys2-portable-"${FLAVOR}") return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# Print portable bin paths under root (one package level). Optionally filter by flavor.
# Args: root [filter_flavor=1]
collect_portable_bins_under() {
  local root="$1"
  local filter="${2:-1}"
  local d base
  [ -d "${root}" ] || return 0
  shopt -s nullglob
  for d in "${root}"/vasp-*-msys2-portable*; do
    [ -d "${d}" ] || continue
    base="$(basename "${d}")"
    # Skip nested junk: require …/bin/vasp_std.exe
    bin_has_vasp "${d}/bin" || continue
    if [ "${filter}" = "1" ]; then
      pkg_basename_matches_flavor "${base}" || continue
    fi
    printf '%s\n' "${d}/bin"
  done
  shopt -u nullglob
}

# Pick exactly one bin from newline list, or die listing candidates.
pick_unique_bin_or_die() {
  local context="$1"
  local list="$2"
  local n
  n="$(printf '%s\n' "${list}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "${n}" -eq 0 ]; then
    return 1
  fi
  if [ "${n}" -gt 1 ]; then
    die "ambiguous portable bin under ${context} (flavor=${FLAVOR}):
$(printf '%s\n' "${list}" | sed '/^$/d' | sed 's/^/  /')
  Set VASP_PORTABLE_BIN=/path/to/bin, or VASP_BUILD_FLAVOR=<name> / PKG_NAME=..."
  fi
  printf '%s\n' "${list}" | sed '/^$/d' | head -1
}

# Die when CURRENT (or similar) has portable packages but none match FLAVOR.
die_wrong_flavor_packages() {
  local context="$1"
  local list="$2"
  local expect
  if [ "${FLAVOR}" = "stock" ]; then
    expect="…-msys2-portable (no -<flavor> suffix)"
  else
    expect="…-msys2-portable-${FLAVOR}"
  fi
  die "no exact ${expect} under ${context} (flavor=${FLAVOR}, PKG_NAME=${PKG_NAME}).
  Found other portable package(s) — refusing silent fallback / stock auto-adopt:
$(printf '%s\n' "${list}" | sed '/^$/d' | sed 's/^/  /')
  Set VASP_PORTABLE_BIN=/path/to/bin, PKG_NAME=<exact-dir>, or VASP_BUILD_FLAVOR=<name>
  to match a candidate."
}

# build_work/<flavor>/<stamp> prefix for a path (empty if outside BUILD_WORK_ROOT).
build_work_stamp_key() {
  local path="$1"
  local bw root_n path_n rel flavor_part rest stamp_part
  bw="$(to_msys_path "${BUILD_WORK_ROOT}")"
  root_n="$(cd "${bw}" 2>/dev/null && pwd -P)" || return 1
  path_n="$(cd "$(dirname "${path}")" 2>/dev/null && pwd -P)/$(basename "${path}")" || path_n="${path}"
  case "${path_n}" in
    "${root_n}"/*) ;;
    *) return 1 ;;
  esac
  rel="${path_n#"${root_n}"/}"
  flavor_part="${rel%%/*}"
  rest="${rel#*/}"
  [ "${rest}" != "${rel}" ] || return 1
  stamp_part="${rest%%/*}"
  [ -n "${flavor_part}" ] && [ -n "${stamp_part}" ] || return 1
  # Require stamp dir shape (not bare CURRENT file path as stamp)
  [ -d "${root_n}/${flavor_part}/${stamp_part}" ] || return 1
  printf '%s/%s' "${flavor_part}" "${stamp_part}"
}

read_flavor_current_stamp() {
  local cf="${BUILD_WORK_ROOT}/${FLAVOR}/CURRENT"
  local stamp
  [ -f "${cf}" ] || return 1
  stamp="$(tr -d '\r\n' < "${cf}")"
  [ -n "${stamp}" ] || return 1
  stamp="$(to_msys_path "${stamp}")"
  [ -d "${stamp}" ] || return 1
  printf '%s' "${stamp}"
}

find_testsuite_under() {
  local root="$1"
  local cand rt
  [ -d "${root}" ] || return 1
  shopt -s nullglob
  for cand in "${root}"/vasp.*/testsuite "${root}"/testsuite; do
    if [ -f "${cand}/runtest" ]; then
      shopt -u nullglob
      printf '%s' "${cand}"
      return 0
    fi
  done
  shopt -u nullglob
  # stamp/vasp.*/testsuite/runtest → depth 3 from stamp; +1–2 from flavor root
  while IFS= read -r rt; do
    [ -n "${rt}" ] || continue
    printf '%s' "$(dirname "${rt}")"
    return 0
  done < <(find "${root}" -maxdepth 5 -type f -name runtest -path '*/testsuite/runtest' 2>/dev/null | sort -r)
  return 1
}

# Prefer PKG_NAME/bin under a stamp/root when present.
try_pkg_name_bin() {
  local root="$1"
  local b="${root}/${PKG_NAME}/bin"
  if bin_has_vasp "${b}"; then
    printf '%s' "${b}"
    return 0
  fi
  return 1
}

#-----------------------------------------------------------------------------
# Locate extracted testsuite (licensed tree under build_work / unpack)
# Never use repo-root /testsuite (inspection copy only).
#-----------------------------------------------------------------------------
resolve_testsuite_root() {
  if [ -n "${TESTSUITE_ROOT:-}" ]; then
    local t
    t="$(to_msys_path "${TESTSUITE_ROOT}")"
    [ -f "${t}/runtest" ] || die "TESTSUITE_ROOT has no runtest: ${t}"
    printf '%s' "$t"
    return 0
  fi

  if [ -n "${SRC_ROOT:-}" ]; then
    local s
    s="$(to_msys_path "${SRC_ROOT}")"
    if [ -f "${s}/testsuite/runtest" ]; then
      printf '%s' "${s}/testsuite"
      return 0
    fi
  fi

  local stamp ts
  if stamp="$(read_flavor_current_stamp)"; then
    if ts="$(find_testsuite_under "${stamp}")"; then
      printf '%s' "${ts}"
      return 0
    fi
  fi

  # Explicit WORK_DIR when it is a stamp (or contains vasp.*/testsuite)
  if [ -d "${WORK_DIR}" ] && [ "${WORK_DIR}" != "${BUILD_WORK_ROOT}" ]; then
    if ts="$(find_testsuite_under "$(to_msys_path "${WORK_DIR}")")"; then
      printf '%s' "${ts}"
      return 0
    fi
  fi

  # Flavor-scoped stamps: build_work/<flavor>/<stamp>/vasp.*/testsuite
  if [ -d "${BUILD_WORK_ROOT}/${FLAVOR}" ]; then
    if ts="$(find_testsuite_under "${BUILD_WORK_ROOT}/${FLAVOR}")"; then
      printf '%s' "${ts}"
      return 0
    fi
  fi

  # Hard-disabled: repo-root /testsuite is for human/agent inspection only.
  if [ -f "${REPO_ROOT}/testsuite/runtest" ]; then
    warn "found ${REPO_ROOT}/testsuite (inspection-only copy; not used for runtest)"
  fi

  die "could not find an extracted VASP testsuite with runtest for flavor=${FLAVOR}.
  Unpack your licensed VASP tarball under build_work/${FLAVOR}/<stamp>/,
  or set TESTSUITE_ROOT=/path/to/vasp.*/testsuite
  (repo-root /testsuite is inspection-only and is never used to run tests)."
}

#-----------------------------------------------------------------------------
# Locate portable bin/ (mpiexec + vasp_*.exe) — generic flavor
# Order: VASP_PORTABLE_BIN > PKG_NAME/CURRENT harvest > exact flavor pattern >
#        WORK_DIR > repo-root > flavor stamps under build_work
# Never silently use a mismatched …-portable* (non-stock miss or stock→other).
#-----------------------------------------------------------------------------
resolve_portable_bin() {
  if [ -n "${VASP_PORTABLE_BIN:-}" ]; then
    local b
    b="$(to_msys_path "${VASP_PORTABLE_BIN}")"
    [ -d "$b" ] || die "VASP_PORTABLE_BIN not a directory: ${b}"
    bin_has_vasp "$b" || die "VASP_PORTABLE_BIN has no vasp_std.exe: ${b}"
    printf '%s' "$b"
    return 0
  fi

  local stamp cand list other

  if stamp="$(read_flavor_current_stamp)"; then
    if cand="$(try_pkg_name_bin "${stamp}")"; then
      printf '%s' "${cand}"
      return 0
    fi
    list="$(collect_portable_bins_under "${stamp}" 1 || true)"
    if cand="$(pick_unique_bin_or_die "CURRENT stamp ${stamp}" "${list}")"; then
      printf '%s' "${cand}"
      return 0
    fi
    # Exact flavor missing under CURRENT: die if any other …-portable* is present
    # (no warn-and-continue with the wrong bin; stock never auto-adopts -<other>).
    other="$(collect_portable_bins_under "${stamp}" 0 || true)"
    if [ -n "$(printf '%s' "${other}" | sed '/^$/d')" ]; then
      die_wrong_flavor_packages "CURRENT stamp ${stamp}" "${other}"
    fi
    warn "CURRENT stamp has no portable bin (PKG_NAME=${PKG_NAME}): ${stamp}"
  fi

  if [ -d "${WORK_DIR}" ] && [ "${WORK_DIR}" != "${BUILD_WORK_ROOT}" ]; then
    local wd
    wd="$(to_msys_path "${WORK_DIR}")"
    if cand="$(try_pkg_name_bin "${wd}")"; then
      printf '%s' "${cand}"
      return 0
    fi
    list="$(collect_portable_bins_under "${wd}" 1 || true)"
    if cand="$(pick_unique_bin_or_die "WORK_DIR ${wd}" "${list}")"; then
      printf '%s' "${cand}"
      return 0
    fi
  fi

  # Repo-root package dirs (exact flavor only — no sole-non-stock adoption)
  list="$(collect_portable_bins_under "${REPO_ROOT}" 1 || true)"
  if cand="$(pick_unique_bin_or_die "repo root" "${list}")"; then
    printf '%s' "${cand}"
    return 0
  fi

  # Deeper under build_work/<flavor>/<stamp>/…
  if [ -d "${BUILD_WORK_ROOT}/${FLAVOR}" ]; then
    if cand="$(try_pkg_name_bin "${BUILD_WORK_ROOT}/${FLAVOR}")"; then
      printf '%s' "${cand}"
      return 0
    fi
    list="$(collect_portable_bins_under "${BUILD_WORK_ROOT}/${FLAVOR}" 1 || true)"
    if cand="$(pick_unique_bin_or_die "build_work/${FLAVOR}" "${list}")"; then
      printf '%s' "${cand}"
      return 0
    fi
    # stamp-nested packages: flavor/<stamp>/vasp-*-msys2-portable*/bin
    list=""
    while IFS= read -r cand; do
      [ -n "${cand}" ] || continue
      bin_has_vasp "${cand}" || continue
      if pkg_basename_matches_flavor "$(basename "$(dirname "${cand}")")"; then
        list="${list}${cand}"$'\n'
      fi
    done < <(find "${BUILD_WORK_ROOT}/${FLAVOR}" -maxdepth 4 -type d -name bin 2>/dev/null | sort -r)
    if cand="$(pick_unique_bin_or_die "build_work/${FLAVOR} stamps" "${list}")"; then
      printf '%s' "${cand}"
      return 0
    fi
  fi

  die "could not find flavor=${FLAVOR} portable bin/ with vasp_std.exe (expected PKG_NAME=${PKG_NAME}).
  Set VASP_PORTABLE_BIN=..., or run a ${FLAVOR} release so build_work/${FLAVOR}/CURRENT
  points at a stamp containing ${PKG_NAME}/bin (convention: stock → …-msys2-portable;
  other flavors → …-msys2-portable-<flavor>; no silent cross-flavor fallback)."
}

#-----------------------------------------------------------------------------
# Build compare_numbertable_new into testsuite/tools/ (ephemeral)
#-----------------------------------------------------------------------------
build_compare_tool() {
  local ts_root="$1"
  local tools="${ts_root}/tools"
  local src="${tools}/compare_numbertable_new.f90"
  local out="${tools}/compare_numbertable_new"
  local fc="${FC:-gfortran}"

  [ -d "${tools}" ] || die "missing tools/: ${tools}"
  [ -f "${src}" ] || die "missing ${src} (expected in licensed VASP testsuite)"

  command -v "${fc}" >/dev/null 2>&1 || die "Fortran compiler not found: ${fc} (open UCRT64 / install gfortran)"

  log "building compare_numbertable_new with ${fc}"
  rm -f "${out}" "${tools}/m_strings.mod"
  (
    cd "${tools}"
    "${fc}" -o compare_numbertable_new compare_numbertable_new.f90
  )
  [ -f "${out}" ] || [ -f "${out}.exe" ] || die "compare_numbertable_new build failed"
  # runtest looks for ./tools/compare_numbertable_new (no .exe); keep both if MinGW emits .exe
  if [ -f "${out}.exe" ] && [ ! -f "${out}" ]; then
    cp -f "${out}.exe" "${out}"
  fi
  log "compare tool ready: ${out}"
}

#-----------------------------------------------------------------------------
# Mode: fast (default) | all  — selects overlay conf (mirrors upstream confs)
#-----------------------------------------------------------------------------
MODE="${MODE:-fast}"
RUNTEST_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast|-f)
      MODE=fast
      shift
      ;;
    --all|-a)
      MODE=all
      shift
      ;;
    --)
      shift
      RUNTEST_ARGS+=("$@")
      break
      ;;
    *)
      RUNTEST_ARGS+=("$1")
      shift
      ;;
  esac
done

case "${MODE}" in
  fast|all) ;;
  *) die "MODE must be fast or all (got: ${MODE})" ;;
esac

# Positional recipe names → VASP_TESTSUITE_TESTS (upstream ignores extras on ./runtest).
# Explicit env wins if already set.
if [ "${#RUNTEST_ARGS[@]}" -gt 0 ]; then
  if [ -n "${VASP_TESTSUITE_TESTS:-}" ]; then
    warn "ignoring positional recipes (${RUNTEST_ARGS[*]}); VASP_TESTSUITE_TESTS already set"
  else
    export VASP_TESTSUITE_TESTS="${RUNTEST_ARGS[*]}"
    log "VASP_TESTSUITE_TESTS=${VASP_TESTSUITE_TESTS}"
  fi
fi

OVERLAY_CONF_NAME="msys2_msmpi_${MODE}.conf"
CONF_BASENAME="${OVERLAY_CONF_NAME}"

#-----------------------------------------------------------------------------
# Main (env + flavor already resolved above)
#-----------------------------------------------------------------------------
log "VASP_BUILD_FLAVOR=${VASP_BUILD_FLAVOR} VASP_VTST=${VASP_VTST} (explicit=${FLAVOR_EXPLICIT}) PKG_NAME=${PKG_NAME}"

TESTSUITE_ROOT="$(resolve_testsuite_root)"
VASP_PORTABLE_BIN="$(resolve_portable_bin)"
VASP_PORTABLE_BIN="$(cd "${VASP_PORTABLE_BIN}" && pwd -P)"
TESTSUITE_ROOT="$(cd "${TESTSUITE_ROOT}" && pwd -P)"

log "VASP_PORTABLE_BIN=${VASP_PORTABLE_BIN}"
log "TESTSUITE_ROOT=${TESTSUITE_ROOT}"

# Loud warning when bin and testsuite sit under different build_work stamps.
_bin_stamp="$(build_work_stamp_key "${VASP_PORTABLE_BIN}" || true)"
_ts_stamp="$(build_work_stamp_key "${TESTSUITE_ROOT}" || true)"
if [ -n "${_bin_stamp}" ] && [ -n "${_ts_stamp}" ] && [ "${_bin_stamp}" != "${_ts_stamp}" ]; then
  warn "portable bin and testsuite come from different build_work stamps:
  bin:       build_work/${_bin_stamp}  (${VASP_PORTABLE_BIN})
  testsuite: build_work/${_ts_stamp}  (${TESTSUITE_ROOT})
  Prefer matching CURRENT / VASP_PORTABLE_BIN / TESTSUITE_ROOT for the same release."
fi
unset _bin_stamp _ts_stamp

# Resolve-only smoke: print paths and exit without compare tool / runtest.
if [ "${TESTSUITE_RESOLVE_ONLY:-0}" = "1" ]; then
  log "TESTSUITE_RESOLVE_ONLY=1 — skipping compare tool and runtest"
  exit 0
fi

OVERLAY_SRC="${OVERLAY_DIR}/${OVERLAY_CONF_NAME}"
[ -f "${OVERLAY_SRC}" ] || die "overlay conf missing: ${OVERLAY_SRC}"

for exe in vasp_std.exe vasp_gam.exe vasp_ncl.exe; do
  [ -f "${VASP_PORTABLE_BIN}/${exe}" ] || die "missing ${VASP_PORTABLE_BIN}/${exe}"
done

MPIEXEC="${VASP_MPIEXEC:-${VASP_PORTABLE_BIN}/mpiexec.exe}"
[ -f "${MPIEXEC}" ] || die "missing mpiexec: ${MPIEXEC}"
export VASP_MPIEXEC="${MPIEXEC}"
export VASP_PORTABLE_BIN
export VASP_TESTSUITE_NRANKS="${VASP_TESTSUITE_NRANKS:-4}"

log "MODE=${MODE}"
log "overlay=${OVERLAY_CONF_NAME}"
if [ -n "${VASP_TESTSUITE_TESTS:-}" ]; then
  log "single/selected recipes: VASP_TESTSUITE_TESTS=${VASP_TESTSUITE_TESTS}"
else
  log "no VASP_TESTSUITE_TESTS — will run full ${MODE} category from overlay"
fi
if [ -n "${MSMPI_WRAP_DEBUG:-}" ] && [ "${MSMPI_WRAP_DEBUG}" != "0" ]; then
  warn "MSMPI_WRAP_DEBUG=${MSMPI_WRAP_DEBUG} — overlay will pass it via mpiexec -env (rank0/rate-limited in current shim). Unset for clean PASS/FAIL logs."
fi

cp -f "${OVERLAY_SRC}" "${TESTSUITE_ROOT}/${CONF_BASENAME}"
log "copied overlay -> ${TESTSUITE_ROOT}/${CONF_BASENAME}"

build_compare_tool "${TESTSUITE_ROOT}"

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
case ":${PATH}:" in
  *":${VASP_PORTABLE_BIN}:"*) ;;
  *) export PATH="${VASP_PORTABLE_BIN}:${PATH}" ;;
esac

# fftlib may dlopen("libfftw3_omp.so") even when the exe is linked to
# libfftw3_threads. If UCRT64 is on PATH, that loads the OpenMP FFTW DLL +
# libgomp into plan creation (bulk_BN_PBE0 n4 SIGSEGV). Drop any PATH entry
# that hosts real libfftw3_omp*, and never leave that DLL in portable bin/.
# Diagnostic override: VASP_TESTSUITE_ALLOW_FFTW_OMP=1 keeps omp DLL / PATH
# for stock-libfftw3_omp A/B (exe must actually link libfftw3_omp).
# (compare_numbertable_new is already built above; gfortran not needed here.)
if [ "${VASP_TESTSUITE_ALLOW_FFTW_OMP:-0}" = "1" ]; then
  log "VASP_TESTSUITE_ALLOW_FFTW_OMP=1 — keep libfftw3_omp on PATH / portable bin"
  if [ ! -f "${VASP_PORTABLE_BIN}/libfftw3_omp-3.dll" ] \
     && [ -f "${MINGW_PREFIX:-/ucrt64}/bin/libfftw3_omp-3.dll" ]; then
    cp -f "${MINGW_PREFIX}/bin/libfftw3_omp-3.dll" "${VASP_PORTABLE_BIN}/"
    log "staged libfftw3_omp-3.dll into portable bin (stock OMP A/B)"
  fi
else
  if [ -f "${VASP_PORTABLE_BIN}/libfftw3_omp-3.dll" ] || [ -f "${VASP_PORTABLE_BIN}/libfftw3_omp.dll" ]; then
    rm -f "${VASP_PORTABLE_BIN}/libfftw3_omp-3.dll" "${VASP_PORTABLE_BIN}/libfftw3_omp.dll"
    log "removed libfftw3_omp*.dll from portable bin (prefer linked libfftw3_threads)"
  fi
  if [ ! -f "${VASP_PORTABLE_BIN}/libfftw3_threads-3.dll" ] && [ -f "${MINGW_PREFIX:-/ucrt64}/bin/libfftw3_threads-3.dll" ]; then
    cp -f "${MINGW_PREFIX}/bin/libfftw3_threads-3.dll" "${VASP_PORTABLE_BIN}/"
    log "staged libfftw3_threads-3.dll into portable bin"
  fi
  _new_path=""
  while IFS= read -r _dir; do
    [ -n "${_dir}" ] || continue
    if [ "${_dir}" != "${VASP_PORTABLE_BIN}" ] \
       && { [ -f "${_dir}/libfftw3_omp-3.dll" ] || [ -f "${_dir}/libfftw3_omp.dll" ]; }; then
      log "PATH: drop ${_dir} (contains libfftw3_omp; avoid fftlib dlopen)"
      continue
    fi
    if [ -z "${_new_path}" ]; then
      _new_path="${_dir}"
    else
      _new_path="${_new_path}:${_dir}"
    fi
  done < <(printf '%s\n' "${PATH}" | tr ':' '\n')
  export PATH="${_new_path}"
  unset _new_path _dir
fi

cd "${TESTSUITE_ROOT}"
# Match upstream ./runtest -f: non-empty TESTS overrules RUN_FAST from the conf.
if [ -n "${VASP_TESTSUITE_TESTS:-}" ]; then
  export VASP_TESTSUITE_RUN_FAST=""
fi
# Upstream CLI: ./runtest [config-file] only — do NOT pass recipe names as argv.
log "running: ./runtest ${CONF_BASENAME}"
set +e
./runtest "${CONF_BASENAME}"
rc=$?
set -e

# Clearer failure footer: upstream SUMMARY can be buried / false-FAIL when
# MSMPI_WRAP_DEBUG used to interleave stderr. Prefer explicit exit + hints.
if [ "${rc}" -ne 0 ]; then
  warn "runtest exited ${rc}"
  if [ -n "${VASP_TESTSUITE_TESTS:-}" ]; then
    _first_recipe="${VASP_TESTSUITE_TESTS%% *}"
    _recipe_dir="${TESTSUITE_ROOT}/tests/${_first_recipe}"
    if [ -d "${_recipe_dir}" ]; then
      log "failure hints for ${_first_recipe}:"
      if [ -f "${_recipe_dir}/FAILED" ]; then
        warn "  marker: ${_recipe_dir}/FAILED"
      fi
      if [ -f "${_recipe_dir}/stdout" ]; then
        log "  last 30 lines of tests/${_first_recipe}/stdout:"
        tail -n 30 "${_recipe_dir}/stdout" 2>/dev/null || true
      elif [ -f "${_recipe_dir}/OUTCAR" ]; then
        log "  OUTCAR present (${_recipe_dir}/OUTCAR); stdout capture missing"
      else
        warn "  no stdout/OUTCAR under ${_recipe_dir} (crash before I/O?)"
      fi
    fi
    unset _first_recipe _recipe_dir
  else
    warn "full ${MODE} run failed — scroll to upstream SUMMARY, or re-run with VASP_TESTSUITE_TESTS=<recipe>"
  fi
  exit "${rc}"
fi
log "runtest OK (exit 0)"
exit 0
