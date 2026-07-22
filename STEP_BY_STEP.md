# VASP Windows Native Build — Step-by-Step Manual

Use this to run the build **one stage at a time** on a Windows host, with a
checkpoint after each stage. For the automated one-command path, prefer
`bash toolchain/build_vasp.sh` (sources `env_ucrt64.sh`, then runs
`build_pipeline.sh`), or call `build_pipeline.sh` directly.

All commands run in the **MSYS2 UCRT64** shell unless noted.

---

## Variables — set once per session

```bash
# >>> adjust these paths >>>
export DELIV="$PWD"
export VASP_TARBALL="/c/Users/you/Downloads/vasp.6.6.0.tar.gz"
export WORK="$DELIV/build_work"

# >>> usually unchanged >>>
export MINGW_PREFIX="/ucrt64"
# Scoop MSYS2: /ucrt64 may be a symlink — resolve for DLL harvest matching
export MINGW_PREFIX="$(cd "$MINGW_PREFIX" && pwd -P)"
export TARGET_CPU="x86-64"
export VASP_CMAKE_DIR="$DELIV/vasp_cmake"
export PATCH_DIR="$DELIV/patches"

echo "DELIV=$DELIV"; echo "TARBALL=$VASP_TARBALL"
[ -f "$VASP_TARBALL" ] || echo "WARNING: tarball path does not resolve yet"
[ -f "$VASP_CMAKE_DIR/setup.sh" ] || echo "WARNING: init submodule (git submodule update --init)"
```

**Checkpoint:** paths look correct; no unexpected WARNING.

---

## Stage 0 — Environment prep (one-time)

### 0.1 Toolchain packages (pacman)

Prefer the repo installer (keeps the package list in sync with the pipeline):

```bash
bash toolchain/install_deps_msys2.sh
```

That installs gcc/gfortran, cmake, ninja, msmpi, OpenBLAS, ScaLAPACK, FFTW,
**zlib**, **dlfcn**, ntldd, git, tar, zip, wget — and **does not** install
pacman `hdf5` (MSYS2 HDF5 pulls `libaws*` into the portable ZIP).

`dlfcn` (`mingw-w64-ucrt-x86_64-dlfcn`) is required when `VASP_FFTLIB=ON`
(pipeline default with OpenMP + FFTW): it provides `dlfcn.h` / `libdl` for
internal fftlib on MinGW.

Equivalent package list (if you must invoke pacman by hand):

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-fortran \
  mingw-w64-ucrt-x86_64-binutils mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-msmpi \
  mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-scalapack \
  mingw-w64-ucrt-x86_64-fftw mingw-w64-ucrt-x86_64-zlib \
  mingw-w64-ucrt-x86_64-dlfcn \
  mingw-w64-ucrt-x86_64-ntldd git tar zip wget
```

### 0.2 Optional libs (HDF5 / LibXC / Wannier90 / DFTD4) — not pacman

Self-build into `toolchain/install/` (writes aggregate `setup` for
`CMAKE_PREFIX_PATH`):

```bash
bash toolchain/scripts/install_optional.sh
# subset: OPTIONAL_LIBS="hdf5 libxc" bash toolchain/scripts/install_optional.sh
```

`toolchain/build_vasp.sh` / `build_pipeline.sh` source that setup so optional
prefixes sit **before** `MINGW_PREFIX`. A bare Stage 4 cmake line below does
**not** — see the advanced note there.

### 0.3 Host Microsoft MPI

```powershell
scoop install msmpi
```

or install `msmpisetup.exe` from Microsoft. Provides `mpiexec.exe`, `smpd.exe`,
`msmpi.dll` for harvesting into the portable package.
Optional override: `MSMPI_BIN=/c/path/to/Microsoft MPI/Bin`.

### 0.4 Verify

```bash
gfortran --version | head -1
cmake --version | head -1
ninja --version
ntldd --version 2>&1 | head -1
ls "$MINGW_PREFIX/include/dlfcn.h"
ls "$MINGW_PREFIX/lib/libmsmpi.dll.a"
ls "$MINGW_PREFIX/lib"/libopenblas*.dll.a
ls "$MINGW_PREFIX/lib"/libscalapack*.dll.a
ls "$VASP_CMAKE_DIR/setup.sh"
```

**Checkpoint:** every command succeeds; `dlfcn.h` present.

---

## Stage 1 — Unpack source & stage CMake port

```bash
rm -rf "$WORK" && mkdir -p "$WORK"
tar -xf "$VASP_TARBALL" -C "$WORK"

SRC_ROOT="$(find "$WORK" -maxdepth 2 -type d -name src -printf '%h\n' | head -1)"
echo "SRC_ROOT=$SRC_ROOT"
[ -n "$SRC_ROOT" ] || { echo "ERROR: no src/ found"; }

rm -rf "$SRC_ROOT/cmake"
cp -a "$VASP_CMAKE_DIR" "$SRC_ROOT/cmake"

# Overlays + DFTD4 enable (pipeline does this in unpack; do the same manually):
cp -f "$DELIV/cmake_overlays/"*.cmake "$SRC_ROOT/cmake/"
patch --forward -p1 -d "$SRC_ROOT" < "$PATCH_DIR/0003-cmake-enable-dftd4.patch" || true
```

**Checkpoint:** `ls "$SRC_ROOT/cmake/setup.sh"` exists; optional
`FindDFTD4.cmake` under `$SRC_ROOT/cmake/`.

---

## Stage 2 — CMakeLists setup (symlinks → real files)

```bash
( cd "$SRC_ROOT" && bash cmake/setup.sh "$SRC_ROOT" )

# Windows CMake often cannot follow MSYS symlinks — materialize:
while IFS= read -r -d '' link; do
  dir="$(dirname "$link")"
  target="$(readlink "$link")"
  rm -f "$link"
  cp -f "$dir/$target" "$link"
done < <(find "$SRC_ROOT" -name CMakeLists.txt -type l -print0)

ls -l "$SRC_ROOT/CMakeLists.txt"
ls -l "$SRC_ROOT/src/CMakeLists.txt"
ls -l "$SRC_ROOT/src/lib/CMakeLists.txt"
```

**Checkpoint:** those paths are regular files (not broken links).

---

## Stage 3 — Apply Win32 / BSE patches

`0003` (DFTD4 CMake enable) is applied when staging `cmake/` (Stage 1 /
pipeline unpack), together with `cmake_overlays/Find*.cmake` — not here.

```bash
cd "$SRC_ROOT"
patch --forward -l -p1 < "$PATCH_DIR/0001-dclock_-win32-getrusage.patch"
patch --forward -l -p1 < "$PATCH_DIR/0002-timing_-win32-getrusage.patch"
patch --forward -l -p1 < "$PATCH_DIR/0004-autoset-available-memory-win32.patch"
patch --forward -l -p1 < "$PATCH_DIR/0005-bse-guard-avpw-zeroing.patch"
patch --forward -l -p1 < "$PATCH_DIR/0006-bse-lqp-force-ibse0.patch"
cd "$DELIV"
```

**Checkpoint:**

```bash
grep -c win32_filetime_to_sec "$SRC_ROOT/src/lib/dclock_.c"   # expect >0
grep -c win32_filetime_to_sec "$SRC_ROOT/src/lib/timing_.c"   # expect >0
grep -c vasp_win32_available_memory_kb "$SRC_ROOT/src/ini.F"  # expect >0
grep -c 'IF (ALLOCATED(AVpW)) AVpW=0' "$SRC_ROOT/src/bse.F"  # expect >0
grep -c 'QPBSE/LQP: forcing IBSE=0' "$SRC_ROOT/src/bse.F"    # expect >0
```

Re-running is safe if a patch says "already applied".
See [docs/WIN32_MAXMEM.md](docs/WIN32_MAXMEM.md) and
[docs/BSE_WIN32_GUARDS.md](docs/BSE_WIN32_GUARDS.md).

The automated pipeline also compiles and links the MS-MPI `--wrap` shim at
configure time ([docs/MSMPI_INPLACE_SHIM.md](docs/MSMPI_INPLACE_SHIM.md)).

---

## Stage 4 — Configure (cmake)

**Recommended:** do not hand-roll cmake. Use the real entry points so MS-MPI
`--wrap` injects, fftlib Win32 inject, and optional-lib `CMAKE_PREFIX_PATH`
prefixes are applied:

```bash
# after Stages 0–3 are already done once, or for a full release from tarball:
bash toolchain/build_vasp.sh "$VASP_TARBALL"
# or: bash build_pipeline.sh "$VASP_TARBALL"
# develop rebuild (reuse build_work): see Optional section below
```

### Advanced / diagnostic only — minimal cmake (unsafe for multi-rank)

The following is a **stripped** configure for debugging Find\* / compiler
paths. It is **not** equivalent to the pipeline:

- **No** MS-MPI `--wrap` shim inject → multi-process (`mpiexec -n >1`) is
  unsafe on MSYS2/MS-MPI (see [docs/MSMPI_INPLACE_SHIM.md](docs/MSMPI_INPLACE_SHIM.md)).
- **No** optional-prefix wiring → self-built HDF5/LibXC/Wannier90/DFTD4 from
  `install_optional.sh` are not on `CMAKE_PREFIX_PATH` unless you add them.
- **No** fftlib Win32 CMake inject (`RTLD_NOLOAD` / related) used when
  `VASP_FFTLIB=ON`.

```bash
BDIR="$SRC_ROOT/build"
rm -rf "$BDIR" && mkdir -p "$BDIR"
# If you already ran install_optional.sh, prepend its prefixes, e.g.:
#   source "$DELIV/toolchain/install/setup"
#   CMAKE_PREFIX="${CMAKE_PREFIX_PATH:+$CMAKE_PREFIX_PATH:}$MINGW_PREFIX"
CMAKE_PREFIX="${CMAKE_PREFIX_PATH:-$MINGW_PREFIX}"
cmake -S "$SRC_ROOT" -B "$BDIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_Fortran_COMPILER=gfortran \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX" \
  -DVASP_OPENMP=ON \
  -DVASP_FFTLIB=ON \
  -DVASP_HDF5=ON \
  -DVASP_SCALAPACK=ON \
  -DVASP_SHMEM=OFF \
  -DVASP_SYSV=OFF \
  -DVASP_TARGET_CPU="$TARGET_CPU" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--stack,268435456" \
  -DBLA_VENDOR=OpenBLAS \
  -DLAPACK_DIR="$MINGW_PREFIX/lib" \
  -DFFTW_ROOT="$MINGW_PREFIX" \
  -DMPI_Fortran_INCLUDE_PATH="$MINGW_PREFIX/include" \
  -DMPI_Fortran_LIBRARIES="$MINGW_PREFIX/lib/libmsmpi.dll.a"
```

**Checkpoint (pipeline path):** configure succeeds with wrap/fftlib injects and
optional prefixes. **Checkpoint (minimal cmake):** Find\* may pass, but do not
treat the binary as multi-rank–safe.

---

## Stage 5 — Build (ninja)

```bash
JOBS="$(nproc)"; mem=$(awk '/^MemTotal:/{printf "%d",$2/1024/1024}' /proc/meminfo)
[ -n "$mem" ] && [ "$mem" -ge 1 ] && { j=$((mem/3)); [ "$j" -lt "$JOBS" ] && JOBS="$j"; }
echo "building with -j$JOBS"

cmake --build "$BDIR" -j "$JOBS"
ls -lh "$BDIR/bin"/vasp_std.exe "$BDIR/bin"/vasp_gam.exe "$BDIR/bin"/vasp_ncl.exe
```

**Checkpoint:** the three executables exist. On OOM, lower `JOBS` / set `NUM_CORES`.

---

## Stage 6 — Harvest DLLs + MS-MPI launcher

Prefer the automated harvest in `build_pipeline.sh` (Scoop real-path matching,
API-set stub ignore). Manual outline:

```bash
PKG="$WORK/vasp-6.6.0-msys2-portable"
rm -rf "$PKG" && mkdir -p "$PKG/bin"

for v in vasp_std vasp_gam vasp_ncl; do
  cp -f "$BDIR/bin/$v.exe" "$PKG/bin/"
done

# Copy recursive MinGW / System32 deps via ntldd (see build_pipeline.sh harvest)
# Then copy host MS-MPI:
MSMPI_BIN="${MSMPI_BIN:-$HOME/scoop/apps/msmpi/current}"
MSMPI_BIN="$(cd "$MSMPI_BIN" && pwd -P)"
for m in mpiexec.exe smpd.exe msmpi.dll msmpires.dll; do
  [ -f "$MSMPI_BIN/$m" ] && cp -f "$MSMPI_BIN/$m" "$PKG/bin/"
done
```

**Checkpoint:** `ntldd` may report `api-ms-*` / `ext-ms-*` as "not found" — ignore
those. Fail only if real `lib*.dll` / `msmpi*.dll` are missing.

---

## Stage 7 — run.bat + zip

```bash
cat > "$PKG/run.bat" <<'BATCH'
@echo off
cd /d "%~dp0"
set PATH=%~dp0bin;%PATH%
set OMP_NUM_THREADS=1
set OPENBLAS_NUM_THREADS=1
echo Starting VASP on 4 cores...
.\bin\mpiexec.exe -n 4 .\bin\vasp_std.exe
pause
BATCH

( cd "$WORK" && zip -qr "$DELIV/vasp-6.6.0-msys2-portable.zip" vasp-6.6.0-msys2-portable )
( cd "$DELIV" && sha256sum vasp-6.6.0-msys2-portable.zip > vasp-6.6.0-msys2-portable.zip.sha256 )
cat "$DELIV/vasp-6.6.0-msys2-portable.zip.sha256"
```

ZIP and checksum are **gitignored** — keep them local.

---

## Stage 8 — Smoke test

Unzip the artifact, drop a small licensed test set (`INCAR POSCAR POTCAR
KPOINTS`), run `run.bat`. Expect `OUTCAR`, `OSZICAR`, `CONTCAR`.

---

## Optional — develop rebuild (no ZIP)

After one successful full unpack/configure (or a prior `release` run), iterate
on shims / patches without wiping `build_work`:

```bash
VASP_PIPELINE_MODE=develop VASP_TARBALL="$VASP_TARBALL" bash "$DELIV/toolchain/build_vasp.sh"
# or: bash "$DELIV/build_pipeline.sh" --develop "$VASP_TARBALL"
# Copy new build/bin/vasp_*.exe over an existing portable bin/ for testsuite.
```

`develop` never `rm -rf` the work tree; it skips harvest / package / zip.
See [docs/DESIGN.md](docs/DESIGN.md).

---

## Quick troubleshooting

| Stage | Symptom | Check |
|---|---|---|
| 0 | package not found | `pacman -Syu` then `bash toolchain/install_deps_msys2.sh` |
| 0 | missing `dlfcn.h` / fftlib fail | install `mingw-w64-ucrt-x86_64-dlfcn` (in `install_deps_msys2.sh`) |
| 0 | HDF5 / `libaws*` from pacman | do **not** `pacman -S …-hdf5`; use `install_optional.sh` |
| 0 | missing `vasp_cmake/setup.sh` | `git submodule update --init --recursive` |
| 2 | CMake cannot see CMakeLists | materialize symlinks (Stage 2) |
| 3 | patch rejected | already applied, or tarball version differs |
| 4 | MPI/OpenBLAS/HDF5 not found | deps + optional setup; prefer `build_vasp.sh` / pipeline |
| 4 | multi-rank crash after hand cmake | missing MS-MPI wrap inject — use pipeline, not minimal cmake |
| 5 | `getrusage` link error | Stage 3 patches not active |
| 5 | stack overflow `0xc00000fd` | confirm `-Wl,--stack,268435456` |
| 5 | OpenBLAS under MPI | keep `OMP_NUM_THREADS=1` |
| 6 | MinGW DLL not found | resolve Scoop `MINGW_PREFIX`; copy missing DLL |
| 6 | `api-ms-*` not found | ignore (OS API-set stubs) |
