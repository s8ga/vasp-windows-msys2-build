# Design notes (thin)

This repository is a **usage-focused deliverable**: scripts and patches to build
a portable VASP Windows package with MSYS2 UCRT64.

## Boundaries

- **In scope:** `build_pipeline.sh`, `patches/`, and the official CMake port as
  a git submodule at `vasp_cmake/` ([vasp-dev/cmake](https://github.com/vasp-dev/cmake),
  branch `6.6.x`).
- **Out of scope:** VASP private source, POTCAR / potpaw archives, portable ZIP
  artifacts, oneAPI reference trees, and long research evidence dumps.

Research and experimental notes live in separate workspaces and are not mirrored
here.

## Pipeline highlights

1. Stage official CMake lists into the unpacked VASP tree; materialize
   `CMakeLists.txt` symlinks as real files so Windows CMake can read them.
2. Apply only Win32 timing patches (`getrusage` → `GetProcessTimes`).
3. Configure with OpenBLAS + MS-MPI + ScaLAPACK + FFTW + HDF5; disable SysV/SHMEM.
4. Harvest runtime DLLs using real MinGW paths (Scoop symlink-aware) and host
   MS-MPI launcher files.
5. Treat Windows API-set stubs (`api-ms-*`, `ext-ms-*`) as non-fatal for
   packaging checks; fail only on missing bundlable MinGW/MS-MPI DLLs.
6. Emit `run.bat` with `OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1`.

## Submodule

```bash
git submodule update --init --recursive
# path: vasp_cmake
# url:  https://github.com/vasp-dev/cmake.git
# branch: 6.6.x
```
