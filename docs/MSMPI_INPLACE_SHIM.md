# MS-MPI `MPI_IN_PLACE` linker wrap shim

English reference for the **fix** shipped in this repo for MSYS2 UCRT64
**gfortran + Microsoft MPI (MS-MPI)** multi-rank runs. Build-glue only; no
proprietary VASP source is discussed here.

Companion history / probes: [MSYS2_MSMPI_MULTIRANK.md](MSYS2_MSMPI_MULTIRANK.md).
Packaging overview: [README.md](../README.md).

---

## Problem

With a stock MSYS2 UCRT64 gfortran portable VASP linked against MS-MPI:

| Probe | Result (before the shim) |
|---|---|
| `mpiexec -n 1` | OK |
| `mpiexec -n 2` (and higher) | Crash (`SIGSEGV` / heap corruption) or silently wrong collective results after MPI setup |
| Same tutorial job under Intel MPI (oneAPI-style package) | Multi-rank OK |

Single-rank works because many broken `MPI_IN_PLACE` paths are unused or
harmless with one process. Multi-rank hits Fortran collectives that pass a
**fake** in-place sentinel into MS-MPI.

---

## Root cause

Public ABI mismatch, not a VASP-specific secret:

1. MS-MPI's Fortran bindings expose `MPI_IN_PLACE` / `MPI_BOTTOM` via `COMMON`
   blocks that expect **MSVC-style `DLLIMPORT`**, so Fortran uses the **same**
   sentinel addresses as the C library (`MPI_IN_PLACE` approx. `(void*)(MPI_Aint)-1`).
2. **gfortran does not honor** that MSVC `DLLIMPORT` on those COMMONs the way
   MSVC / Intel Fortran do.
3. Fortran therefore passes `&mpipriv1_.mpi_in_place` (a normal process
   address) instead of the real C sentinel. Collectives that key off the
   sentinel then **corrupt memory** or return **wrong answers**.

References: [GCC Bug 47030](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=47030),
Stack Overflow [a/58123046](https://stackoverflow.com/a/58123046), MS-MPI /
MinGW Fortran interoperability discussions, Elmer's
`ELMER_BROKEN_MPI_IN_PLACE` notes.

Black-box confirmation: under gfortran + MS-MPI, `loc(MPI_IN_PLACE)` is a fake
local pointer; inplace `MPI_Allreduce` can return zeros while non-inplace
Allreduce is correct.

---

## What we changed (shim + pipeline)

### Files

| Path | Role |
|---|---|
| [`shim/msmpi_inplace_wrap.c`](../shim/msmpi_inplace_wrap.c) | GNU ld `--wrap` implementations: remap fake COMMON to C `MPI_IN_PLACE` / `MPI_BOTTOM`, then call the **C** MPI API |
| [`shim/cmake_msmpi_wrap_inject.cmake`](../shim/cmake_msmpi_wrap_inject.cmake) | `CMAKE_PROJECT_TOP_LEVEL_INCLUDES` helper: apply `--wrap` + object **only** to `vasp_std` / `vasp_gam` / `vasp_ncl` (not CMake `try_compile`) |
| [`build_pipeline.sh`](../build_pipeline.sh) `configure()` | Compiles the `.c` to `msmpi_inplace_wrap.o`, passes `-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=...`, `-DVASP_MSMPI_WRAP_OBJ=...`, `-DVASP_MSMPI_WRAP_SYMS=...` |

### Link strategy (important)

Do **not** put `-Wl,--wrap=...` or the wrap object into global
`CMAKE_EXE_LINKER_FLAGS`. That breaks CMake Fortran compiler tests.

Stack size stays on `CMAKE_EXE_LINKER_FLAGS`; wraps are attached per VASP
executable target via the inject script (`cmake_language(DEFER ...)` after
targets exist).

Default symbol list (`MSMPI_WRAP_SYMS`, space-separated in the shell):

```text
mpi_allreduce_ mpi_reduce_ mpi_allgather_ mpi_allgatherv_
mpi_gather_ mpi_alltoall_ mpi_alltoallv_ mpi_iallgather_ mpi_get_
```

Override with `MSMPI_WRAP_SYMS='...'` if `nm` on `vasp_std.exe` shows more
Fortran stubs that take `sendbuf` / `MPI_IN_PLACE`. Optional runtime tracing:
`MSMPI_WRAP_DEBUG=1`.

---

## Why it works

GNU ld `--wrap=mpi_foo_` redirects calls to `mpi_foo_` toward
`__wrap_mpi_foo_`.

Each wrapper:

1. Compares `sendbuf` (or origin for `mpi_get_`) to
   `&mpipriv1_.mpi_in_place` / `&mpipriv1_.mpi_bottom`.
2. If equal, substitutes the real C `MPI_IN_PLACE` / `MPI_BOTTOM`.
3. Invokes the matching **C** collective (`MPI_Allreduce`, ...) with
   `MPI_Type_f2c` / `MPI_Comm_f2c` conversions.

MS-MPI then sees the sentinel it expects. No gfortran rebuild and no
proprietary VASP edits are required.

---

## How to verify

1. **Minimal probe** (Allreduce): build the inplace probe with and without
   `--wrap`; without wrap, inplace Allreduce is wrong; with wrap,
   `mpiexec -n 1` and `-n 2` match non-inplace.
2. **Package smoke** (tutorial-sized job, same inputs):
   - `mpiexec -n 1` -> exit 0, final `F` in `OSZICAR`
   - `mpiexec -n 2` -> exit 0, `F` matches `-n 1` within normal numeric noise
   - `mpiexec -n 4` -> exit 0, same
3. Optional cross-check: Intel MPI (oneAPI) package on the same job should
   land on the same final `F` (different MPI, same physics).
4. Confirm the binary was linked with wraps and that the launcher is MS-MPI
   (`mpiexec` from Microsoft MPI, not `impi`).

Example energies observed on a small tutorial job with the wrapped MSYS2
portable ZIP (2026-07-21): final `F` approx. `-0.3145693` for `-n 1` / `-n 2` /
`-n 4`, matching oneAPI `-n 1` / `-n 2` on the same job.

---

## Limitations (which MPI calls are wrapped)

Only the Fortran stub names listed in `MSMPI_WRAP_SYMS` are intercepted.
**Default set:**

- `mpi_allreduce_`, `mpi_reduce_`
- `mpi_allgather_`, `mpi_allgatherv_`, `mpi_gather_`
- `mpi_alltoall_`, `mpi_alltoallv_`, `mpi_iallgather_`
- `mpi_get_` (RMA origin may use `MPI_BOTTOM`)

**Not wrapped by default** (non-exhaustive): other collectives / RMA /
neighborhood collectives (`mpi_bcast_` is usually fine without inplace;
`mpi_scatter*`, `mpi_reduce_scatter*`, `mpi_put_`, `mpi_accumulate_`,
nonblocking variants beyond `iallgather`, etc.). If a future workload crashes
or disagrees across rank counts, inspect Fortran MPI stubs with `nm` and extend
`MSMPI_WRAP_SYMS` plus matching `__wrap_*` functions in
`shim/msmpi_inplace_wrap.c`.

Other limits:

- Fix is for **gfortran + MS-MPI**. Intel MPI packages do not need this shim.
- Older portable ZIPs built **without** the shim remain unsafe for multi-rank
  MS-MPI; rebuild with current `build_pipeline.sh`.
- The shim does not replace a correct compiler / `DLLIMPORT` fix upstream; it is
  a practical link-time workaround.

---

## Policy

Aligned with [AGENTS.md](../AGENTS.md): do not commit ZIPs / `build_work/` /
tarballs / `POTCAR`; do not push unless asked; do not load proprietary VASP
sources into review context when debugging this class of issue.
