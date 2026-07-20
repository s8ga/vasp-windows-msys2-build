# VASP Windows Native Build — Step-by-Step Manual

Use this to run the build **one stage at a time** on a Windows host, with a
checkpoint after each stage. For the automated one-command path, use
`build_pipeline.sh`.

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

### 0.1 Toolchain packages

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-fortran \
  mingw-w64-ucrt-x86_64-binutils mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-msmpi \
  mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-scalapack \
  mingw-w64-ucrt-x86_64-fftw mingw-w64-ucrt-x86_64-hdf5 \
  mingw-w64-ucrt-x86_64-ntldd git tar zip
```

### 0.2 Host Microsoft MPI

```powershell
scoop install msmpi
```

or install `msmpisetup.exe` from Microsoft. Provides `mpiexec.exe`, `smpd.exe`,
`msmpi.dll` for harvesting into the portable package.

### 0.3 Verify

```bash
gfortran --version | head -1
cmake --version | head -1
ninja --version
ntldd --version 2>&1 | head -1
ls "$MINGW_PREFIX/lib/libmsmpi.dll.a"
ls "$MINGW_PREFIX/lib"/libopenblas*.dll.a
ls "$MINGW_PREFIX/lib"/libscalapack*.dll.a
ls "$VASP_CMAKE_DIR/setup.sh"
```

**Checkpoint:** every command succeeds.

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
```

**Checkpoint:** `ls "$SRC_ROOT/cmake/setup.sh"` exists.

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

## Stage 3 — Apply Win32 timing patches

```bash
cd "$SRC_ROOT"
patch --forward -p1 < "$PATCH_DIR/0001-dclock_-win32-getrusage.patch"
patch --forward -p1 < "$PATCH_DIR/0002-timing_-win32-getrusage.patch"
cd "$DELIV"
```

**Checkpoint:**

```bash
grep -c win32_filetime_to_sec "$SRC_ROOT/src/lib/dclock_.c"   # expect >0
grep -c win32_filetime_to_sec "$SRC_ROOT/src/lib/timing_.c"   # expect >0
```

Re-running is safe if a patch says "already applied".

---

## Stage 4 — Configure (cmake)

```bash
BDIR="$SRC_ROOT/build"
rm -rf "$BDIR" && mkdir -p "$BDIR"
cmake -S "$SRC_ROOT" -B "$BDIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_Fortran_COMPILER=gfortran \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_PREFIX_PATH="$MINGW_PREFIX" \
  -DVASP_OPENMP=ON \
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

**Checkpoint:** configure finds MPI (Fortran), OpenBLAS, ScaLAPACK, FFTW, HDF5.

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

## Quick troubleshooting

| Stage | Symptom | Check |
|---|---|---|
| 0 | package not found | `pacman -Syu` then retry |
| 0 | missing `vasp_cmake/setup.sh` | `git submodule update --init --recursive` |
| 2 | CMake cannot see CMakeLists | materialize symlinks (Stage 2) |
| 3 | patch rejected | already applied, or tarball version differs |
| 4 | MPI/OpenBLAS not found | packages + MPI Fortran hints in Stage 4 |
| 5 | `getrusage` link error | Stage 3 patches not active |
| 5 | stack overflow `0xc00000fd` | confirm `-Wl,--stack,268435456` |
| 5 | OpenBLAS under MPI | keep `OMP_NUM_THREADS=1` |
| 6 | MinGW DLL not found | resolve Scoop `MINGW_PREFIX`; copy missing DLL |
| 6 | `api-ms-*` not found | ignore (OS API-set stubs) |
