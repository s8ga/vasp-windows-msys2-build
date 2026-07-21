#!/usr/bin/env bash
# =============================================================================
# run_testsuite.sh — run VASP testsuite against a portable MSYS2/MS-MPI build
#
# UCRT64 shell:
#   bash toolchain/run_testsuite.sh
#   bash toolchain/run_testsuite.sh --fast
#   TESTSUITE_ROOT=/c/path/to/vasp.6.6.0/testsuite \
#     VASP_PORTABLE_BIN=/c/path/to/vasp-*-msys2-portable/bin \
#     bash toolchain/run_testsuite.sh
#
# This repo does NOT ship the licensed testsuite/. The runner:
#   1) Locates extracted SRC_ROOT/testsuite (or TESTSUITE_ROOT)
#   2) Copies testsuite_overlays/msys2_msmpi.conf into that directory
#   3) Builds compare_numbertable_new into testsuite/tools/ (ephemeral)
#   4) Sets thread env + PATH, then runs ./runtest with the overlay conf
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OVERLAY_DIR="${TESTSUITE_OVERLAY_DIR:-${REPO_ROOT}/testsuite_overlays}"
OVERLAY_CONF_NAME="${OVERLAY_CONF_NAME:-msys2_msmpi.conf}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build_work}"
CONF_BASENAME="${OVERLAY_CONF_NAME}"

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
# Locate extracted testsuite (licensed tree under build_work / unpack)
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

  local cand ts
  # Prefer build_work/vasp.*/testsuite (find returns .../testsuite/runtest file path)
  if [ -d "${WORK_DIR}" ]; then
    while IFS= read -r cand; do
      ts="$(dirname "${cand}")"
      if [ -f "${ts}/runtest" ]; then
        printf '%s' "${ts}"
        return 0
      fi
    done < <(find "${WORK_DIR}" -maxdepth 3 -type f -name runtest -path '*/testsuite/runtest' 2>/dev/null | sort -r)
  fi

  # Accidental unpack beside repo (gitignored) — still usable, never committed
  if [ -f "${REPO_ROOT}/testsuite/runtest" ]; then
    warn "using ${REPO_ROOT}/testsuite (gitignored licensed tree); prefer WORK_DIR unpack"
    printf '%s' "${REPO_ROOT}/testsuite"
    return 0
  fi

  die "could not find testsuite/runtest. Set TESTSUITE_ROOT=.../testsuite or unpack VASP under WORK_DIR=${WORK_DIR}"
}

#-----------------------------------------------------------------------------
# Locate portable bin/ (mpiexec + vasp_*.exe)
#-----------------------------------------------------------------------------
resolve_portable_bin() {
  if [ -n "${VASP_PORTABLE_BIN:-}" ]; then
    local b
    b="$(to_msys_path "${VASP_PORTABLE_BIN}")"
    [ -d "$b" ] || die "VASP_PORTABLE_BIN not a directory: ${b}"
    printf '%s' "$b"
    return 0
  fi

  local cand
  for cand in \
    "${REPO_ROOT}/vasp-6.6.0-msys2-portable/bin" \
    "${WORK_DIR}/vasp-6.6.0-msys2-portable/bin"
  do
    if [ -x "${cand}/vasp_std.exe" ] || [ -f "${cand}/vasp_std.exe" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done

  # Any unpacked portable package under repo or WORK_DIR
  while IFS= read -r cand; do
    if [ -f "${cand}/vasp_std.exe" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done < <(find "${REPO_ROOT}" "${WORK_DIR}" -maxdepth 3 -type d -name bin 2>/dev/null | sort -r)

  die "could not find portable bin/ with vasp_std.exe. Set VASP_PORTABLE_BIN=..."
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
# Main
#-----------------------------------------------------------------------------
# Optional: source UCRT64 env when available (PATH / MINGW_PREFIX)
if [ -f "${SCRIPT_DIR}/env_ucrt64.sh" ] && [ "${SKIP_ENV_UCRT64:-}" != "1" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/env_ucrt64.sh" || warn "env_ucrt64.sh returned non-zero; continuing"
fi

TESTSUITE_ROOT="$(resolve_testsuite_root)"
VASP_PORTABLE_BIN="$(resolve_portable_bin)"
VASP_PORTABLE_BIN="$(cd "${VASP_PORTABLE_BIN}" && pwd -P)"
TESTSUITE_ROOT="$(cd "${TESTSUITE_ROOT}" && pwd -P)"

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

log "TESTSUITE_ROOT=${TESTSUITE_ROOT}"
log "VASP_PORTABLE_BIN=${VASP_PORTABLE_BIN}"
log "overlay=${OVERLAY_CONF_NAME}"

cp -f "${OVERLAY_SRC}" "${TESTSUITE_ROOT}/${CONF_BASENAME}"
log "copied overlay -> ${TESTSUITE_ROOT}/${CONF_BASENAME}"

build_compare_tool "${TESTSUITE_ROOT}"

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
case ":${PATH}:" in
  *":${VASP_PORTABLE_BIN}:"*) ;;
  *) export PATH="${VASP_PORTABLE_BIN}:${PATH}" ;;
esac

# Extra args after -- are passed to runtest; bare --fast/--all replace default conf mode
RUNTEST_ARGS=()
USE_CONF=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast|--all|-f|-a)
      USE_CONF=0
      RUNTEST_ARGS+=("$1")
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

cd "${TESTSUITE_ROOT}"
if [ "${USE_CONF}" -eq 1 ]; then
  log "running: ./runtest ${CONF_BASENAME} ${RUNTEST_ARGS[*]:-}"
  ./runtest "${CONF_BASENAME}" ${RUNTEST_ARGS[@]+"${RUNTEST_ARGS[@]}"}
else
  # --fast/--all: still export EXE_* from overlay by sourcing it first
  # shellcheck disable=SC1090
  source "${TESTSUITE_ROOT}/${CONF_BASENAME}"
  log "running: ./runtest ${RUNTEST_ARGS[*]}"
  ./runtest "${RUNTEST_ARGS[@]}"
fi
