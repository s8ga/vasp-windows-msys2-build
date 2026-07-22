# Design notes (thin)

This repository is a **usage-focused deliverable**: scripts and patches to build
a portable VASP Windows package with MSYS2 UCRT64.

## Boundaries

- **In scope:** `build_pipeline.sh`, `patches/`, `shim/`, `cmake_overlays/`,
  `toolchain/` (including optional `scripts/inject_vtst.sh`),
  `testsuite_overlays/`, and the official CMake port as a git submodule at
  `vasp_cmake/` ([vasp-dev/cmake](https://github.com/vasp-dev/cmake),
  branch `6.6.x`).
- **Out of scope:** VASP private source, POTCAR / potpaw archives, portable ZIP
  artifacts, vtstcode trees, oneAPI reference trees, and long research evidence
  dumps.

Research and experimental notes live in separate workspaces and are not mirrored
here.

## Work-tree layout

Each **release** gets a new stamp directory under a flavor root. Stock and VTST
never share a tree:

```text
build_work/
  stock/
    <YYYYMMDD-HHMMSS>/
    CURRENT                 # latest successful stock release path
  vtst/
    <YYYYMMDD-HHMMSS>/
    CURRENT
```

- `VASP_VTST=OFF` (default) → flavor `stock`; package
  `vasp-6.6.0-msys2-portable`
- `VASP_VTST=ON` → flavor `vtst`; package name gains `-vtst`; requires
  user-supplied `VTST_CODE_DIR` (see [VTST.md](VTST.md))
- Explicit `WORK_DIR` overrides stamp / `CURRENT` resolution
- No automatic cleanup of old stamps

## Pipeline highlights

1. Stage official CMake lists into the unpacked VASP tree; copy
   **`cmake_overlays/`** (`FindDFTD4.cmake`, `FindLibXC.cmake`) into staged
   `cmake/` (do **not** edit the submodule in place); apply
   `patches/0003-cmake-enable-dftd4.patch` to staged `CMakeLists_root.txt` so
   `-DVASP_DFTD4=ON` (pipeline default) can `find_package(DFTD4)`.
2. Materialize `CMakeLists.txt` symlinks as real files so Windows CMake can
   read them. After unpack, also materialize relative `testsuite/POTCARS/`
   symlinks listed by `tar -tvf` as real `cp` copies (Windows often fails to
   create those links); toggle with `VASP_MATERIALIZE_POTCAR_LINKS` (default
   `1`).
3. Apply Win32 / validation patches idempotently:
   - `0001` / `0002` — timing (`getrusage` → `GetProcessTimes`)
   - `0004` — MAXMEM auto-detect (`/proc/meminfo` → `GlobalMemoryStatusEx`;
     see [WIN32_MAXMEM.md](WIN32_MAXMEM.md))
   - `0005` / `0006` — BSE / QPBSE guards (`AVpW` ALLOCATED; LQP force
     `IBSE=0`; see [BSE_WIN32_GUARDS.md](BSE_WIN32_GUARDS.md))
4. **Optional VTST inject** (`VASP_VTST=ON`): after patch, before configure —
   overlay user vtstcode via `toolchain/scripts/inject_vtst.sh` (core `*.F`
   including `ml_pyamff.F`, `pyamff_fortran/` + CMake overlay, `main.F`,
   `.objects`, staged `CMakeLists_src.txt` link). See [VTST.md](VTST.md).
5. Configure with OpenBLAS + MS-MPI + ScaLAPACK + FFTW + HDF5 (+ optional
   LibXC / Wannier90 / DFTD4 from `toolchain/install`); disable SysV/SHMEM.
6. Link the **MS-MPI Fortran sentinel `--wrap` shim**
   ([MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md)) plus FFTW planner / Win32
   MAXMEM helpers via `CMAKE_PROJECT_TOP_LEVEL_INCLUDES` injects (never put
   `--wrap` on global `CMAKE_EXE_LINKER_FLAGS`). BLACS TopsRepeat wrap stays
   **default OFF**; GOMP SRW named-critical wrap
   (`VASP_GOMP_CRITICAL_WIN32`) stays **default OFF**.
7. Harvest runtime DLLs using real MinGW paths (Scoop symlink-aware) and host
   MS-MPI launcher files.
8. Treat Windows API-set stubs (`api-ms-*`, `ext-ms-*`) as non-fatal for
   packaging checks; fail only on missing bundlable MinGW/MS-MPI DLLs.
9. Emit `run.bat` that **keeps the caller’s CWD** (job directory with `INCAR`);
   binaries are resolved from `%~dp0bin`. Pin
   `OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1`.

Release stage order (abbreviated):

`preflight → unpack → setup → patch → [inject_vtst] → configure → build → harvest → package → write CURRENT`

## Modes

| Mode | Behavior |
| --- | --- |
| `release` (default) | New `build_work/<flavor>/<stamp>/`; full pipeline through portable ZIP; update `CURRENT` |
| `develop` | Reuse `build_work/<flavor>/CURRENT` (or `WORK_DIR`); re-apply patches / optional VTST inject; rebuild only; skip harvest / package / zip |

```bash
VASP_PIPELINE_MODE=develop VASP_TARBALL=/c/path/to/vasp.tgz bash build_pipeline.sh
# or: bash build_pipeline.sh --develop /c/path/to/vasp.tgz
# VTST develop: VASP_VTST=ON VTST_CODE_DIR=... (uses build_work/vtst/CURRENT)
```

## Submodule

```bash
git submodule update --init --recursive
# path: vasp_cmake
# url:  https://github.com/vasp-dev/cmake.git
# branch: 6.6.x
```
