#!/usr/bin/env bash
# =============================================================================
# build_pipeline.sh — VASP 6.6.x Windows-native build (MSYS2 UCRT64, C2 route)
#
# One-command pipeline:  VASP tarball  -->  portable green ZIP artifact
#
# Run inside an MSYS2 *UCRT64* shell:
#     VASP_TARBALL=/c/path/to/vasp.6.6.0.tgz bash build_pipeline.sh
# or
#     bash build_pipeline.sh /c/path/to/vasp.6.6.0.tgz
#
# VASP_TARBALL may be MSYS (/c/...) or Windows (C:\... / C:/...); preflight
# normalizes via to_msys_path before the existence check.
#
# Co-located assets (relative to this script):
#   ./vasp_cmake/        official CMake port (setup.sh, CMakeLists/, Find*.cmake)
#   ./patches/           0001/0002 timing + 0003 DFTD4 CMake enable
#   ./cmake_overlays/    FindDFTD4.cmake / FindLibXC.cmake (copied into staged cmake/)
#   ./toolchain/install/ self-built HDF5/LibXC/Wannier90/DFTD4 (via install/setup)
#
# Pipeline stages: preflight, unpack, setup, patch, configure, build, harvest,
#                  package, zip
# =============================================================================
set -euo pipefail

#-----------------------------------------------------------------------------
# Configuration (override via environment)
#-----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VASP_TARBALL="${VASP_TARBALL:-${1:-}}"
VASP_CMAKE_DIR="${VASP_CMAKE_DIR:-${SCRIPT_DIR}/vasp_cmake}"
PATCH_DIR="${PATCH_DIR:-${SCRIPT_DIR}/patches}"
CMAKE_OVERLAY_DIR="${CMAKE_OVERLAY_DIR:-${SCRIPT_DIR}/cmake_overlays}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${SCRIPT_DIR}/toolchain}"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/build_work}"
BUILD_DIR_NAME="${BUILD_DIR_NAME:-build}"
PKG_NAME="${PKG_NAME:-vasp-6.6.0-msys2-portable}"
MINGW_PREFIX="${MINGW_PREFIX:-/ucrt64}"
TARGET_CPU="${TARGET_CPU:-x86-64}"
BUILD_VARIANTS="${BUILD_VARIANTS:-vasp_std vasp_gam vasp_ncl}"
# Optional features (ON/OFF). Disable individually if configure/link fails.
VASP_HDF5="${VASP_HDF5:-ON}"
VASP_LIBXC="${VASP_LIBXC:-ON}"
VASP_WANNIER90="${VASP_WANNIER90:-ON}"
VASP_DFTD4="${VASP_DFTD4:-ON}"
# NUM_CORES — optional override for ninja -j (else RAM-capped nproc)

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

stage() { # stage <n> <name>
  log "[$1] $2"
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
  log "features: HDF5=${VASP_HDF5} LIBXC=${VASP_LIBXC} WANNIER90=${VASP_WANNIER90} DFTD4=${VASP_DFTD4}"
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

  local need=(gfortran gcc cmake ninja ntldd zip patch sha256sum)
  for t in "${need[@]}"; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool '$t' (pacman -S mingw-w64-ucrt-x86_64-... / msys tools)"
  done

  resolve_mingw_prefix
  log "MINGW_PREFIX=${MINGW_PREFIX} (real=${MINGW_PREFIX_REAL})"

  # Self-built optional libs (CMAKE_PREFIX_PATH before MINGW_PREFIX)
  source_toolchain_optional

  # key libraries present?
  local lib="${MINGW_PREFIX}/lib"
  [ -f "${lib}/libmsmpi.dll.a" ]    || warn "libmsmpi.dll.a not in ${lib} (msmpi pkg?)"
  ls "${lib}"/libopenblas*.dll.a >/dev/null 2>&1 || warn "OpenBLAS import lib not in ${lib}"

  log "toolchain OK (gfortran=$(gfortran -dumpversion), cmake=$(cmake --version | head -1 | awk '{print $3}'))"
  log "tarball: ${VASP_TARBALL}"
}

#-----------------------------------------------------------------------------
# [1] unpack — extract source, locate root, stage vasp_cmake as cmake/
#-----------------------------------------------------------------------------
unpack() {
  stage 1 "unpack"
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}"
  log "extracting ${VASP_TARBALL} ..."
  # On Windows, relative symlinks under testsuite/POTCARS often fail and make
  # GNU tar exit non-zero. Those links are not required to compile VASP — keep
  # going if src/ is present.
  set +e
  tar -xf "${VASP_TARBALL}" -C "${WORK_DIR}"
  local tar_rc=$?
  set -e
  if [ "${tar_rc}" -ne 0 ]; then
    warn "tar exited ${tar_rc} (often Windows symlink failures under testsuite/POTCARS); continuing if src/ exists"
  fi

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
# [3] patch — apply Win32 timing patches (idempotent)
#-----------------------------------------------------------------------------
patch_sources() {
  stage 3 "patch (dclock_.c / timing_.c Win32)"
  # explicit file -> patch mapping (robust; no name guessing)
  local entries=(
    "src/lib/dclock_.c|${PATCH_DIR}/0001-dclock_-win32-getrusage.patch"
    "src/lib/timing_.c|${PATCH_DIR}/0002-timing_-win32-getrusage.patch"
  )
  local entry f p
  for entry in "${entries[@]}"; do
    f="${entry%%|*}"; p="${entry#*|}"
    [ -f "$p" ] || { warn "patch missing: $p"; continue; }
    if grep -q "win32_filetime_to_sec" "${SRC_ROOT}/${f}" 2>/dev/null; then
      log "already patched: $f"; continue
    fi
    if patch --dry-run --forward -p1 -d "${SRC_ROOT}" < "$p" >/dev/null 2>&1; then
      patch --forward -p1 -d "${SRC_ROOT}" < "$p" && log "applied $(basename "$p") -> $f"
    else
      warn "patch not clean (maybe applied): $(basename "$p")"
    fi
  done
  grep -q "win32_filetime_to_sec" "${SRC_ROOT}/src/lib/dclock_.c" || die "dclock_.c patch not active"
  grep -q "win32_filetime_to_sec" "${SRC_ROOT}/src/lib/timing_.c" || die "timing_.c patch not active"
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
# Symbols discovered via nm on vasp_std (collectives / RMA that may see IN_PLACE or BOTTOM)
MSMPI_WRAP_SYMS="${MSMPI_WRAP_SYMS:-mpi_allreduce_ mpi_reduce_ mpi_allgather_ mpi_allgatherv_ mpi_gather_ mpi_alltoall_ mpi_alltoallv_ mpi_iallgather_ mpi_get_}"

msmpi_wrap_syms_cmake() { # semicolon-separated list for CMake cache
  local s out=""
  for s in ${MSMPI_WRAP_SYMS}; do
    if [ -z "${out}" ]; then out="${s}"; else out="${out};${s}"; fi
  done
  printf '%s' "${out}"
}

compile_msmpi_wrap() { # compile_msmpi_wrap <outdir> -> sets MSMPI_WRAP_OBJ (mixed path)
  local outdir="$1"
  mkdir -p "${outdir}"
  local obj_unix="${outdir}/msmpi_inplace_wrap.o"
  [ -f "${MSMPI_WRAP_SRC}" ] || die "missing MS-MPI wrap shim: ${MSMPI_WRAP_SRC}"
  [ -f "${MSMPI_WRAP_INJECT}" ] || die "missing MS-MPI wrap CMake inject: ${MSMPI_WRAP_INJECT}"
  gcc -c "${MSMPI_WRAP_SRC}" -I"${MINGW_PREFIX}/include" -o "${obj_unix}"
  # Ninja/cmd.exe linker prefers Windows mixed paths over /c/...
  if command -v cygpath >/dev/null 2>&1; then
    MSMPI_WRAP_OBJ="$(cygpath -m "${obj_unix}")"
  else
    MSMPI_WRAP_OBJ="${obj_unix}"
  fi
  log "compiled MS-MPI IN_PLACE wrap: ${MSMPI_WRAP_OBJ}"
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
  local inject_path
  if command -v cygpath >/dev/null 2>&1; then
    inject_path="$(cygpath -m "${MSMPI_WRAP_INJECT}")"
  else
    inject_path="${MSMPI_WRAP_INJECT}"
  fi
  # Re-apply optional env in case configure is invoked alone.
  source_toolchain_optional
  local cmake_prefix
  cmake_prefix="$(cmake_prefix_path_for_cmake)"
  log "MS-MPI wrap symbols: ${wrap_syms_cm}"
  log "CMAKE_PROJECT_TOP_LEVEL_INCLUDES=${inject_path}"
  log "CMAKE_PREFIX_PATH (cmake)=${cmake_prefix}"
  cmake -S "${SRC_ROOT}" -B "${BDIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_Fortran_COMPILER=gfortran \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_PREFIX_PATH="${cmake_prefix}" \
    -DVASP_OPENMP=ON \
    -DVASP_HDF5="${VASP_HDF5}" \
    -DVASP_LIBXC="${VASP_LIBXC}" \
    -DVASP_WANNIER90="${VASP_WANNIER90}" \
    -DVASP_DFTD4="${VASP_DFTD4}" \
    -DVASP_SCALAPACK=ON \
    -DVASP_SHMEM=OFF \
    -DVASP_SYSV=OFF \
    -DVASP_TARGET_CPU="${TARGET_CPU}" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--stack,268435456" \
    -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="${inject_path}" \
    -DVASP_MSMPI_WRAP_OBJ="${MSMPI_WRAP_OBJ}" \
    -DVASP_MSMPI_WRAP_SYMS="${wrap_syms_cm}" \
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
cd /d "%~dp0"
set PATH=%~dp0bin;%PATH%
REM OpenBLAS (MSYS2) is OpenMP-threaded; under mpiexec -n N each rank must use
REM a single BLAS thread, otherwise cores are oversubscribed and OpenBLAS's
REM buffer allocator can fail. Pin both vars (OMP_NUM_THREADS is authoritative).
set OMP_NUM_THREADS=1
set OPENBLAS_NUM_THREADS=1
REM Multi-rank MS-MPI requires the MPI_IN_PLACE --wrap shim linked at build
REM time (shim/msmpi_inplace_wrap.c). See docs/MSYS2_MSMPI_MULTIRANK.md.
REM Optional: set MSMPI_WRAP_DEBUG=1 to log sentinel rewrites.
echo Starting VASP on 4 cores...
.\bin\mpiexec.exe -n 4 .\bin\vasp_std.exe
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
  log "VASP Windows-native build (MSYS2 UCRT64, route C2)"
  preflight
  unpack
  setup
  patch_sources
  configure
  build
  harvest
  package
  log "DONE — green portable ZIP at ${SCRIPT_DIR}/${PKG_NAME}.zip"
}

main "$@"
