#!/usr/bin/env bash
# =============================================================================
# install_deps_msys2.sh — install MSYS2 UCRT64 build packages for this repo
#
# Thin entry point only. Does not compile VASP; run from an MSYS2 UCRT64 shell:
#     bash toolchain/install_deps_msys2.sh
#
# Host Microsoft MPI (mpiexec harvest) is separate — see tip at the end.
# =============================================================================
set -euo pipefail

log()  { printf '\033[1;34m[deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

if [ "${MSYSTEM:-}" != "UCRT64" ]; then
  if [ "${ALLOW_NON_UCRT64:-}" = "1" ]; then
    warn "MSYSTEM=${MSYSTEM:-unset} (expected UCRT64); continuing due to ALLOW_NON_UCRT64=1"
  else
    die "MSYSTEM=${MSYSTEM:-unset}; open an MSYS2 UCRT64 shell (or set ALLOW_NON_UCRT64=1)"
  fi
fi

command -v pacman >/dev/null 2>&1 || die "pacman not found; run inside MSYS2"

log "installing UCRT64 build packages via pacman ..."
# NOTE: Do NOT install mingw-w64-ucrt-x86_64-hdf5 — MSYS2 HDF5 pulls aws-c-*
# (libaws*) into the portable ZIP. HDF5 is self-built via toolchain/scripts
# (Wave 1+: install_hdf5.sh, ROS3 off). Keep zlib for that build.
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-fortran \
  mingw-w64-ucrt-x86_64-binutils mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-msmpi \
  mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-scalapack \
  mingw-w64-ucrt-x86_64-fftw mingw-w64-ucrt-x86_64-zlib \
  mingw-w64-ucrt-x86_64-ntldd git tar zip wget

log "MSYS2 packages OK."
cat <<'EOF'

NOTE: Optional libs (HDF5 / LibXC / Wannier90 / DFTD4) are NOT from pacman.
      Build them later with: bash toolchain/scripts/install_optional.sh

Host Microsoft MPI (required so the pipeline can harvest mpiexec/smpd into the
portable ZIP). Install once on Windows, e.g. in PowerShell:

  scoop install msmpi

or the official runtime (msmpisetup.exe) from:
  https://www.microsoft.com/download/details.aspx?id=100362

Optional override later: MSMPI_BIN=/c/path/to/Microsoft MPI/Bin

Next:
  source toolchain/env_ucrt64.sh
  bash toolchain/build_vasp.sh /c/path/to/vasp.6.6.0.tar.gz

EOF
