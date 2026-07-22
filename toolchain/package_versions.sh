#!/usr/bin/env bash
# =============================================================================
# package_versions.sh — pins for optional toolchain libraries (VASP Windows)
#
# Adapted from ABACUS toolchain/scripts/package_versions.sh (libxc, dftd4).
# HDF5 and Wannier90 pins are local to this repo (ABACUS does not ship them).
#
# Each package MUST have ver / sha256 / url. Install scripts download via
# tool_kit retrieve_package; archives are SHA256-verified before any extract.
#
# Usage: source this file, then call load_package_vars "<name>"
# =============================================================================

# HDF5 — self-built with ROS3/VFD off (no libaws* in portable ZIP)
hdf5_ver="1.14.6"
hdf5_sha256="e4defbac30f50d64e1556374aa49e574417c9e72c6b1de7a4ff88c4b1bea6e9b"
hdf5_url="https://github.com/HDFGroup/hdf5/releases/download/hdf5_${hdf5_ver}/hdf5-${hdf5_ver}.tar.gz"

# LibXC (GitLab archive; latest 7.1.x)
libxc_ver="7.1.2"
libxc_sha256="3915fac94416e4c415534223ea492ad2663f928acf27e98662c861b094a6c306"
libxc_url="https://gitlab.com/libxc/libxc/-/archive/${libxc_ver}/libxc-${libxc_ver}.tar.bz2"

# Wannier90
wannier90_ver="3.1.0"
wannier90_sha256="40651a9832eb93dec20a8360dd535262c261c34e13c41b6755fa6915c936b254"
wannier90_url="https://github.com/wannier-developers/wannier90/archive/v${wannier90_ver}.tar.gz"

# DFT-D4 (ABACUS pin; build with -DWITH_API_V2=ON for VASP)
# Checksum is for the official release .tar.xz (same as ABACUS).
dftd4_ver="4.2.0"
dftd4_sha256="467e024071510ad82b862c66c383c2ebc164fc1140e15dfc79f48d2f999fd184"
dftd4_url="https://github.com/dftd4/dftd4/releases/download/v${dftd4_ver}/dftd4-${dftd4_ver}.tar.xz"

# VTST / vtstcode (Henkelman group; Apache-2.0). Source-only overlay for VASP 6.6.x.
# Pin is the GitHub archive of the named commit (contains vtstcode6.6.0/).
# Not in the default OPTIONAL_LIBS list — install via install_vtst.sh or
# OPTIONAL_LIBS="... vtst".
vtst_ver="6.6.0"
vtst_subdir="vtstcode6.6.0"
vtst_commit="e34035138dded5e4436832eb2b7801247ca4c60d"
vtst_sha256="423592fdb0b3d027e100ea57de2d797dd5b8f4badd17a0ee72c5e0be196e56e0"
vtst_url="https://github.com/henkelmangroup/vtstcode/archive/${vtst_commit}.tar.gz"

load_package_vars() {
  local package_name="$1"
  case "${package_name}" in
    hdf5)
      : # vars already set
      ;;
    libxc)
      : # vars already set
      ;;
    wannier90)
      : # vars already set
      ;;
    dftd4)
      : # vars already set
      ;;
    vtst)
      : # vars already set
      ;;
    *)
      echo "Error: Unknown package '${package_name}'" >&2
      return 1
      ;;
  esac
}

