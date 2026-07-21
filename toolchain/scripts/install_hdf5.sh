#!/usr/bin/env bash
# =============================================================================
# install_hdf5.sh — build HDF5 into toolchain/install/hdf5-<ver>
#
# Slim VASP recipe: shared-only (no static), tools OFF, all-warnings OFF.
# Fortran ON; HL ON; CPP OFF; SZIP OFF; ROS3/S3/AWS OFF; FLOAT16 OFF.
#
# Checksum: retrieve_package + extract_verified_archive (tool_kit.sh).
# SHA256 must match package_versions.sh BEFORE extract; mismatch deletes file.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../package_versions.sh
source "${TOOLCHAIN_ROOT}/package_versions.sh"
# shellcheck source=../lib/tool_kit.sh
source "${TOOLCHAIN_ROOT}/lib/tool_kit.sh"

SCRIPT_NAME="install_hdf5.sh"
load_package_vars hdf5

BUILDDIR="${TOOLCHAIN_BUILDDIR:-${TOOLCHAIN_ROOT}/build}"
INSTALL_ROOT="${TOOLCHAIN_INSTALL_ROOT:-${TOOLCHAIN_ROOT}/install}"
pkg_install_dir="${INSTALL_ROOT}/hdf5-${hdf5_ver}"
hdf5_pkg="hdf5-${hdf5_ver}.tar.gz"
src_dir="${BUILDDIR}/hdf5-${hdf5_ver}"
build_dir="${BUILDDIR}/hdf5-${hdf5_ver}-build"
install_lock_file="${pkg_install_dir}/install_successful"
setup_file="${BUILDDIR}/setup_hdf5"
JOBS="$(toolchain_jobs)"

mkdir -p "${BUILDDIR}" "${INSTALL_ROOT}"
cd "${BUILDDIR}"

# If an existing build tree was configured with static libs, wipe it.
if [ -f "${build_dir}/CMakeCache.txt" ]; then
  if grep -q '^BUILD_STATIC_LIBS:BOOL=ON' "${build_dir}/CMakeCache.txt" 2>/dev/null; then
    echo "${SCRIPT_NAME}: BUILD_STATIC_LIBS=ON in cache — wiping ${build_dir}"
    rm -rf "${build_dir}"
  elif ! grep -q '^BUILD_STATIC_LIBS:BOOL=OFF' "${build_dir}/CMakeCache.txt" 2>/dev/null; then
    echo "${SCRIPT_NAME}: BUILD_STATIC_LIBS not OFF in cache — wiping ${build_dir}"
    rm -rf "${build_dir}"
  fi
fi

if [ -f "${install_lock_file}" ] && [ -d "${pkg_install_dir}/lib" ]; then
  echo "${SCRIPT_NAME}: hdf5-${hdf5_ver} already installed at ${pkg_install_dir}; writing setup and exiting."
else
  echo "==================== Installing HDF5 ${hdf5_ver} (slim) ===================="

  retrieve_package "${hdf5_sha256}" "${hdf5_pkg}" "${hdf5_url}"

  echo "Installing from scratch into ${pkg_install_dir}"
  # Keep verified tarball; wipe src/build only
  rm -rf "${src_dir}" "${build_dir}"
  extract_verified_archive "${hdf5_sha256}" "${hdf5_pkg}"

  if [ ! -d "${src_dir}" ]; then
    found="$(find "${BUILDDIR}" -maxdepth 1 -type d \( -name "hdf5-${hdf5_ver}" -o -name "hdf5-hdf5_${hdf5_ver}" \) | head -n1 || true)"
    if [ -z "${found}" ]; then
      found="$(find "${BUILDDIR}" -maxdepth 1 -type d -name "hdf5*" ! -name "*-build" ! -name "*.tar.gz" | head -n1 || true)"
    fi
    if [ -n "${found}" ] && [ -f "${found}/CMakeLists.txt" ]; then
      src_dir="${found}"
    else
      report_error "could not locate extracted HDF5 source under ${BUILDDIR}"
      exit 1
    fi
  fi

  mkdir -p "${build_dir}"
  cd "${build_dir}"

  # Slim VASP cmake recipe (+ UCRT64 GCC workarounds).
  cmake "${src_dir}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${pkg_install_dir}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DHDF5_INSTALL_LIB_DIR=lib \
    -DCMAKE_C_FLAGS="-Wno-error=incompatible-pointer-types -Wno-incompatible-pointer-types" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DHDF5_BUILD_FORTRAN=ON \
    -DHDF5_BUILD_HL_LIB=ON \
    -DHDF5_BUILD_CPP_LIB=OFF \
    -DHDF5_BUILD_JAVA=OFF \
    -DHDF5_BUILD_EXAMPLES=OFF \
    -DHDF5_BUILD_TOOLS=OFF \
    -DHDF5_ENABLE_ALL_WARNINGS=OFF \
    -DHDF5_ENABLE_Z_LIB_SUPPORT=ON \
    -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
    -DHDF5_ENABLE_PARALLEL=OFF \
    -DHDF5_ENABLE_ROS3_VFD=OFF \
    -DHDF5_ENABLE_DIRECT_VFD=OFF \
    -DHDF5_ENABLE_MIRROR_VFD=OFF \
    -DHDF5_ENABLE_HDFS=OFF \
    -DHDF5_ENABLE_NONSTANDARD_FEATURE_FLOAT16=OFF \
    -DHDF5_ALLOW_EXTERNAL_SUPPORT=NO \
    -DBUILD_TESTING=OFF \
    > "${BUILDDIR}/hdf5-cmake.log" 2>&1 || {
      tail -n 80 "${BUILDDIR}/hdf5-cmake.log" >&2
      report_error "cmake configure failed (see ${BUILDDIR}/hdf5-cmake.log)"
      exit 1
    }

  # Confirm slim config landed in cache
  if ! grep -q '^BUILD_STATIC_LIBS:BOOL=OFF' CMakeCache.txt; then
    report_error "BUILD_STATIC_LIBS is not OFF after configure"
    grep 'BUILD_STATIC_LIBS' CMakeCache.txt || true
    exit 1
  fi

  cmake --build . -j "${JOBS}" > "${BUILDDIR}/hdf5-build.log" 2>&1 || {
    tail -n 80 "${BUILDDIR}/hdf5-build.log" >&2
    report_error "cmake build failed (see ${BUILDDIR}/hdf5-build.log)"
    exit 1
  }

  cmake --install . > "${BUILDDIR}/hdf5-install.log" 2>&1 || {
    tail -n 80 "${BUILDDIR}/hdf5-install.log" >&2
    report_error "cmake install failed (see ${BUILDDIR}/hdf5-install.log)"
    exit 1
  }

  if find "${pkg_install_dir}" \( -name 'libaws*' -o -name '*aws-c-*' -o -name '*aws-crt*' \) 2>/dev/null | grep -q .; then
    report_error "libaws* / aws artifacts found under ${pkg_install_dir}; abort"
    find "${pkg_install_dir}" \( -name 'libaws*' -o -name '*aws-c-*' -o -name '*aws-crt*' \) 2>/dev/null || true
    exit 1
  fi

  date -u +"%Y-%m-%dT%H:%M:%SZ hdf5-${hdf5_ver} ok" > "${install_lock_file}"
  echo "${SCRIPT_NAME}: installed to ${pkg_install_dir}"
fi

cat > "${setup_file}" << EOF
# Generated by ${SCRIPT_NAME} — source from an MSYS2 UCRT64 shell
# HDF5 ${hdf5_ver} (slim: shared-only, ROS3/S3/AWS VFD disabled)
export HDF5_ROOT="${pkg_install_dir}"
export HDF5_DIR="${pkg_install_dir}"
prepend_path PATH "${pkg_install_dir}/bin"
prepend_path LD_LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path LIBRARY_PATH "${pkg_install_dir}/lib"
prepend_path CPATH "${pkg_install_dir}/include"
prepend_path PKG_CONFIG_PATH "${pkg_install_dir}/lib/pkgconfig"
prepend_path CMAKE_PREFIX_PATH "${pkg_install_dir}"
EOF

mkdir -p "${pkg_install_dir}"
cat > "${pkg_install_dir}/setup_hdf5.env" << EOF
# Generated by ${SCRIPT_NAME}
export HDF5_ROOT="${pkg_install_dir}"
export HDF5_DIR="${pkg_install_dir}"
case ":\${PATH}:" in *":${pkg_install_dir}/bin:"*) ;; *) export PATH="${pkg_install_dir}/bin\${PATH:+:\${PATH}}" ;; esac
case ":\${CMAKE_PREFIX_PATH:}:" in *":${pkg_install_dir}:"*) ;; *) export CMAKE_PREFIX_PATH="${pkg_install_dir}\${CMAKE_PREFIX_PATH:+:\${CMAKE_PREFIX_PATH}}" ;; esac
case ":\${PKG_CONFIG_PATH:}:" in *":${pkg_install_dir}/lib/pkgconfig:"*) ;; *) export PKG_CONFIG_PATH="${pkg_install_dir}/lib/pkgconfig\${PKG_CONFIG_PATH:+:\${PKG_CONFIG_PATH}}" ;; esac
EOF

cp -f "${setup_file}" "${INSTALL_ROOT}/setup_hdf5"
echo "${SCRIPT_NAME}: wrote ${setup_file} and ${INSTALL_ROOT}/setup_hdf5"
echo "${SCRIPT_NAME}: CMAKE_PREFIX_PATH tip -> ${pkg_install_dir}"
report_timing "hdf5"