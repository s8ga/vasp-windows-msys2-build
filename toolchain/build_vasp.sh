#!/usr/bin/env bash
# =============================================================================
# build_vasp.sh — thin wrapper: env + root build_pipeline.sh
#
# Usage (MSYS2 UCRT64 shell, from repo root or any cwd):
#     bash toolchain/build_vasp.sh /c/path/to/vasp.6.6.0.tar.gz
#     VASP_TARBALL=/c/path/to/vasp.6.6.0.tar.gz bash toolchain/build_vasp.sh
#
# Single source of truth for the build remains ../build_pipeline.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PIPELINE="${REPO_ROOT}/build_pipeline.sh"

# shellcheck source=env_ucrt64.sh
source "${SCRIPT_DIR}/env_ucrt64.sh"

[ -f "${PIPELINE}" ] || {
  printf '\033[1;31m[err ]\033[0m missing build_pipeline.sh at %s\n' "${PIPELINE}" >&2
  exit 1
}

exec bash "${PIPELINE}" "$@"
