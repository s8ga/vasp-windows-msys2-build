#!/usr/bin/env bash
# =============================================================================
# env_ucrt64.sh — export UCRT64 / MS-MPI environment for this repo
#
# Source (do not execute) from an MSYS2 UCRT64 shell:
#     source toolchain/env_ucrt64.sh
#
# Sets PATH, MINGW_PREFIX, MSMPI_BIN, and optional-lib CMAKE_PREFIX_PATH
# (toolchain/install prefixes before MINGW_PREFIX). Does not build VASP;
# the single build driver remains ../build_pipeline.sh.
#
# Optional gitignored overrides: copy local.env.example → local.env, then e.g.
#     export VASP_TARBALL='/c/Users/you/Downloads/vasp.6.6.0.tgz'
# From PowerShell before launching UCRT64 (inherited by child processes):
#     $env:VASP_TARBALL='C:\Users\you\Downloads\vasp.6.6.0.tgz'
# =============================================================================

# Allow `bash env_ucrt64.sh` to print a hint instead of silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  printf '%s\n' "Usage: source toolchain/env_ucrt64.sh" >&2
  exit 2
fi

_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${_ENV_DIR}/local.env" ]; then
  # shellcheck disable=SC1091
  source "${_ENV_DIR}/local.env"
fi

_env_log()  { printf '\033[1;34m[env ]\033[0m %s\n' "$*"; }
_env_warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }

if [ "${MSYSTEM:-}" != "UCRT64" ]; then
  if [ "${ALLOW_NON_UCRT64:-}" = "1" ]; then
    _env_warn "MSYSTEM=${MSYSTEM:-unset} (expected UCRT64); continuing due to ALLOW_NON_UCRT64=1"
  else
    printf '\033[1;31m[err ]\033[0m %s\n' \
      "MSYSTEM=${MSYSTEM:-unset}; open an MSYS2 UCRT64 shell (or set ALLOW_NON_UCRT64=1)" >&2
    unset _ENV_DIR
    unset -f _env_log _env_warn
    return 1 2>/dev/null || exit 1
  fi
fi

export MSYSTEM="${MSYSTEM:-UCRT64}"
export MINGW_PREFIX="${MINGW_PREFIX:-/ucrt64}"

# Prefer UCRT64 tools on PATH (idempotent if already first).
case ":${PATH}:" in
  *":${MINGW_PREFIX}/bin:"*) ;;
  *) export PATH="${MINGW_PREFIX}/bin:${PATH}" ;;
esac

# Resolve Scoop symlink for consistent DLL harvest matching (optional).
if [ -d "${MINGW_PREFIX}" ]; then
  MINGW_PREFIX="$(cd "${MINGW_PREFIX}" && pwd -P)"
  export MINGW_PREFIX
fi

# Discover host MS-MPI Bin if not already set.
if [ -z "${MSMPI_BIN:-}" ]; then
  _msmpi_candidates=(
    "${HOME}/scoop/apps/msmpi/current"
    "/c/Program Files/Microsoft MPI/Bin"
    "/c/Program Files (x86)/Microsoft MPI/Bin"
  )
  for _c in "${_msmpi_candidates[@]}"; do
    if [ -f "${_c}/mpiexec.exe" ] || [ -f "${_c}/mpiexec" ]; then
      MSMPI_BIN="$(cd "${_c}" && pwd -P)"
      export MSMPI_BIN
      break
    fi
  done
  unset _c _msmpi_candidates
fi

if [ -n "${MSMPI_BIN:-}" ]; then
  case ":${PATH}:" in
    *":${MSMPI_BIN}:"*) ;;
    *) export PATH="${MSMPI_BIN}:${PATH}" ;;
  esac
  _env_log "MSMPI_BIN=${MSMPI_BIN}"
else
  _env_warn "MSMPI_BIN not set (install host MS-MPI: scoop install msmpi)"
fi

# Optional self-built libs: toolchain prefixes first, then MINGW_PREFIX.
_OPT_SETUP="${_ENV_DIR}/install/setup"
if [ ! -f "${_OPT_SETUP}" ] && [ -f "${_ENV_DIR}/scripts/write_aggregate_setup.sh" ] && \
   [ -d "${_ENV_DIR}/install" ]; then
  bash "${_ENV_DIR}/scripts/write_aggregate_setup.sh" >/dev/null 2>&1 || true
fi
if [ -f "${_OPT_SETUP}" ]; then
  # shellcheck disable=SC1090
  source "${_OPT_SETUP}"
  case ":${CMAKE_PREFIX_PATH:-}:" in
    *":${MINGW_PREFIX}:"*) ;;
    *) export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:+${CMAKE_PREFIX_PATH}:}${MINGW_PREFIX}" ;;
  esac
  _env_log "sourced ${_OPT_SETUP}"
  _env_log "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH:-}"
else
  _env_warn "optional setup missing (${_OPT_SETUP}); run bash toolchain/scripts/install_optional.sh"
fi
unset _OPT_SETUP

_env_log "MSYSTEM=${MSYSTEM} MINGW_PREFIX=${MINGW_PREFIX}"
unset _ENV_DIR
unset -f _env_log _env_warn
