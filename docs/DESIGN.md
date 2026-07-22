# Design notes (thin)

This repository is a **usage-focused deliverable**: scripts and patches to build
a portable VASP Windows package with MSYS2 UCRT64.

## Boundaries

- **In scope:** `build_pipeline.sh`, `patches/`, `shim/`, `cmake_overlays/`,
  `toolchain/`, `testsuite_overlays/`, and the official CMake port as a git
  submodule at `vasp_cmake/` ([vasp-dev/cmake](https://github.com/vasp-dev/cmake),
  branch `6.6.x`).
- **Out of scope:** VASP private source, POTCAR / potpaw archives, portable ZIP
  artifacts, oneAPI reference trees, and long research evidence dumps.

Research and experimental notes live in separate workspaces and are not mirrored
here.

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
4. Configure with OpenBLAS + MS-MPI + ScaLAPACK + FFTW + HDF5 (+ optional
   LibXC / Wannier90 / DFTD4 from `toolchain/install`); disable SysV/SHMEM.
5. Link the **MS-MPI Fortran sentinel `--wrap` shim**
   ([MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md)) plus FFTW planner / Win32
   MAXMEM helpers via `CMAKE_PROJECT_TOP_LEVEL_INCLUDES` injects (never put
   `--wrap` on global `CMAKE_EXE_LINKER_FLAGS`). BLACS TopsRepeat wrap stays
   **default OFF**; GOMP SRW named-critical wrap
   (`VASP_GOMP_CRITICAL_WIN32`) stays **default OFF**.
6. Harvest runtime DLLs using real MinGW paths (Scoop symlink-aware) and host
   MS-MPI launcher files.
7. Treat Windows API-set stubs (`api-ms-*`, `ext-ms-*`) as non-fatal for
   packaging checks; fail only on missing bundlable MinGW/MS-MPI DLLs.
8. Emit `run.bat` with `OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1`.

## Modes

| Mode | Behavior |
| --- | --- |
| `release` (default) | Full pipeline through portable ZIP |
| `develop` | Reuse existing `build_work` (never `rm -rf`); re-apply patches / wrap objects; rebuild only; skip harvest / package / zip |

```bash
VASP_PIPELINE_MODE=develop VASP_TARBALL=/c/path/to/vasp.tgz bash build_pipeline.sh
# or: bash build_pipeline.sh --develop /c/path/to/vasp.tgz
```

## Submodule

```bash
git submodule update --init --recursive
# path: vasp_cmake
# url:  https://github.com/vasp-dev/cmake.git
# branch: 6.6.x
```
