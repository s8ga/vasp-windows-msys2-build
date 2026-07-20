# MSYS2 / MS-MPI multi-rank: debug saga and known fix paths

> **The fix (start here):** linker `--wrap` shim -- see
> **[MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md)** (Problem, root cause,
> pipeline changes, verification, wrapped MPI list).
> This page keeps the longer probe history and ranked alternatives.

This note records what was observed while running the **MSYS2 UCRT64 gfortran**
portable VASP package under **Microsoft MPI (MS-MPI)** with more than one rank.
It is intentionally **black-box / build-glue** oriented: symptoms, public root
cause, and ranked mitigations. It does **not** quote or analyze proprietary VASP
source.

Related packaging context: [README.md](../README.md), [DESIGN.md](DESIGN.md).

---

## Symptoms

Observed with the MSYS2 UCRT64 gfortran portable build on a small tutorial job:

| Probe | Result |
|---|---|
| `mpiexec -n 1` | **PASS** |
| `mpiexec -n 2` | Crash after MPI setup inside MS-MPI (`SIGSEGV` / Windows `0xc0000374`) |
| gdb stack (high level) | Failure path through Fortran collective wrappers into `PMPI_Bcast` (setup / map-related broadcast) |
| `OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1` | Already set in `run.bat`; did **not** prevent the `-n 2` crash |
| Scoop MS-MPI <-> official MS-MPI swap | Did **not** fix multi-rank |

Control experiments (same machine / same style of job where noted):

| Probe | Result |
|---|---|
| Minimal gfortran program: `MPI_INTEGER` `MPI_Bcast`, `mpiexec -n 2` | **PASS** |
| Separate **oneAPI** portable ZIP on the same tutorial job | `-n 1` and `-n 2` both **PASS**, but that package uses **Intel MPI (`impi`)**, not MS-MPI |
| Black-box Fortran probe of `loc(MPI_IN_PLACE)` under MS-MPI + gfortran | Address is a **fake in-process** pointer, **not** the C sentinel `-1` |
| `MPI_Allreduce(..., MPI_IN_PLACE, ...)` under that broken sentinel | **Silently wrong** (e.g. zeros) |
| Non-inplace `MPI_Allreduce` | **PASS** |

Takeaway: single-rank MS-MPI works; multi-rank fails in real VASP collectives that
use Fortran `MPI_IN_PLACE` / related sentinels. A tiny typed `Bcast` can still
pass. An Intel MPI package is not evidence that MS-MPI multi-rank is fine.

---

## Root cause (public)

This is a long-standing **gfortran <-> MSVC-style MS-MPI Fortran binding** mismatch,
not a VASP-specific bug list we found publicly.

**Mechanism (public accounts):**

- MS-MPI’s Fortran headers expose `MPI_IN_PLACE` / `MPI_BOTTOM` via `COMMON`
  blocks that expect **MSVC-style `DLLIMPORT`** semantics so the Fortran
  runtime uses the same sentinel addresses as the C MPI library.
- **gfortran does not honor** that MSVC `DLLIMPORT` on those COMMONs the way
  MSVC / Intel compilers do.
- Result: Fortran sees a **wrong sentinel** for `MPI_IN_PLACE` (and related
  symbols). Collectives that rely on the real sentinel then **corrupt memory**
  or return **wrong answers** without always crashing.

**Public references (starting points):**

- [GCC Bug 47030](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=47030) -- gfortran
  / DLLIMPORT / COMMON interaction
- Stack Overflow [57535963](https://stackoverflow.com/questions/57535963) and
  answer [a/58123046](https://stackoverflow.com/a/58123046) -- MS-MPI + gfortran
  `MPI_IN_PLACE` / `DLLIMPORT` workaround discussion
- Microsoft-MPI GitHub issues discussing Fortran / MinGW interoperability
- Elmer FEM: `ELMER_BROKEN_MPI_IN_PLACE` (and related docs) as an example of a
  project that documents this class of brokenness and works around it

No claim is made here that any one patch is sufficient for every VASP code path;
the black-box probes above only establish that the sentinel is wrong under stock
MSYS2 gfortran + MS-MPI.

---

## Fix / mitigation options (ranked)

Documented from most practical for this repo’s users to most advanced.

### 1. Linker `--wrap` C shim (integrated in this repo) -- preferred for MS-MPI

Full write-up: [MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md).

Full write-up: [MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md).

Stock MSYS2 gfortran does not need a rebuilt compiler. At **link** time we:

1. Compile [`shim/msmpi_inplace_wrap.c`](../shim/msmpi_inplace_wrap.c).
2. Pass the object plus `-Wl,--wrap=mpi_<sym>_` for each wrapped Fortran stub.
3. Each wrapper maps the fake Fortran COMMON address
   (`&mpipriv1_.mpi_in_place` / `&mpipriv1_.mpi_bottom`) to the real C
   sentinels `MPI_IN_PLACE` / `MPI_BOTTOM`, then calls the **C** MPI API.

`build_pipeline.sh` `configure()` enables this automatically.

**Exact link fragment** (also logged at configure time):

```text
gcc -c shim/msmpi_inplace_wrap.c -I${MINGW_PREFIX}/include -o build/msmpi_inplace_wrap.o

# Stack only on CMAKE_EXE_LINKER_FLAGS (must not put --wrap here -- breaks
# CMake Fortran try_compile). Per-target inject via:
#   -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=shim/cmake_msmpi_wrap_inject.cmake
#   -DVASP_MSMPI_WRAP_OBJ=<mixed-path>/msmpi_inplace_wrap.o
#   -DVASP_MSMPI_WRAP_SYMS=mpi_allreduce_;mpi_reduce_;...

# Effective final link options on vasp_std / vasp_gam / vasp_ncl:
  -Wl,--stack,268435456
  -Wl,--wrap=mpi_allreduce_
  -Wl,--wrap=mpi_reduce_
  -Wl,--wrap=mpi_allgather_
  -Wl,--wrap=mpi_allgatherv_
  -Wl,--wrap=mpi_gather_
  -Wl,--wrap=mpi_alltoall_
  -Wl,--wrap=mpi_alltoallv_
  -Wl,--wrap=mpi_iallgather_
  -Wl,--wrap=mpi_get_
  + msmpi_inplace_wrap.o
```

Override the symbol list with `MSMPI_WRAP_SYMS` (space-separated in the
shell; converted to CMake `;` list) if `nm` on `vasp_std.exe` shows additional
collectives that take `sendbuf` / `MPI_IN_PLACE`.

Optional: `MSMPI_WRAP_DEBUG=1` prints when a fake sentinel is rewritten.

**Black-box probe (Allreduce only):** `%TEMP%\mpi-inplace-wrap-test` --
nowrap returns zeros; wrap passes `mpiexec -n 1` and `-n 2`.

### 2. Product guidance (fallback / other stacks)

If the wrap shim is not linked (older packages):

- Treat **`mpiexec -n 1`** as the safe posture for that MS-MPI package.
- For **multi-rank** without the shim, use a package built against
  **Intel MPI + MKL** (oneAPI-style zip that already passes `-n 2` in our checks).

“Works under Intel MPI” ≠ “an old MS-MPI package without the wrap is fixed.”

### 3. Black-box compiler workaround (`DLLIMPORT` attributes)

Some public write-ups suggest forcing import semantics in Fortran, e.g.:

```fortran
!GCC$ ATTRIBUTES DLLIMPORT :: MPI_BOTTOM, MPI_IN_PLACE
```

**Caveats for this project:**

- Reports often imply a **patched gfortran**, not necessarily stock MinGW.
- **Uncertainty with stock MSYS2 gfortran 16**: do not assume the directive alone
  restores the real MS-MPI sentinels without verification
  (`loc(MPI_IN_PLACE)` / inplace Allreduce probes).
- Even if the sentinel looks correct, full VASP multi-rank still needs an
  end-to-end job check.

### 4. Rebuild gfortran with a COMMON / attribute patch (advanced)

Rebuild or vendor a gfortran that correctly implements the required COMMON /
`DLLIMPORT` behavior (along the lines discussed in GCC bug traffic and SO).
This is an advanced toolchain project, outside the normal
`build_pipeline.sh` workflow.

### 5. Different MPI stack

Alternatives that avoid the broken MS-MPI Fortran sentinel path:

- **WSL + OpenMPI** (Linux MPI stack; different packaging story)
- **Intel MPI with gfortran**, if a workable binding / link line is available
  in your environment

These are environment changes, not a one-line fix inside the current MS-MPI
portable ZIP.

### 6. What is **not** a fix

The following were tried or considered and do **not** address the sentinel bug:

| Approach | Why it is not a fix |
|---|---|
| Larger stack / OpenMP tuning | Crash persists with `OMP`/`OPENBLAS` already at 1 |
| `NPAR=1` (or similar INCAR knobs) | Does not repair wrong `MPI_IN_PLACE` |
| Swapping Scoop <-> winget/official MS-MPI alone | Same Fortran ABI issue remains |

---

## What we did not find

- No public, VASP-maintainer-curated “MS-MPI `Bcast` / collective patch list”
  that would make stock MSYS2 gfortran + MS-MPI multi-rank safe.
- No evidence that packaging-only changes (DLL harvest, `run.bat` env vars,
  launcher swap) correct the Fortran sentinel.

If a future public fix appears (gfortran, MS-MPI headers, or an explicit
upstream binding note), update this document and re-run the black-box probes
before advertising multi-rank MS-MPI support.

---

## Policy (this repository)

Aligned with [AGENTS.md](../AGENTS.md):

- Do **not** commit portable ZIPs, `build_work/`, VASP tarballs, or `POTCAR` /
  potpaw material.
- Do **not** `git push` unless the user explicitly asks (this repo often has no
  remotes configured).
- Do **not** load proprietary VASP sources from extract trees into agent or
  review context when debugging this class of issue; use logs, exit codes,
  minimal MPI probes, and public references instead.

---

## Suggested verification checklist

After any claimed fix (gfortran patch, MPI swap, or new package):

1. `loc(MPI_IN_PLACE)` equals the C/MS-MPI sentinel expectation (not a random
   in-process fake).
2. Inplace `MPI_Allreduce` matches non-inplace on a known buffer.
3. Tutorial (or equivalent) job: `mpiexec -n 1` and `mpiexec -n 2` both PASS
   under the **same** MPI stack you intend to ship.
4. Confirm the launcher is the stack you think it is (`msmpi` vs `impi`).
