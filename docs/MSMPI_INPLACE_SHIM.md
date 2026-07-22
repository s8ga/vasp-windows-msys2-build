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

Single-rank works because many broken sentinel paths are unused or harmless
with one process. Multi-rank hits Fortran collectives that pass fake
`MPI_IN_PLACE` or `MPI_STATUSES_IGNORE` addresses into MS-MPI.

---

## Root cause

Public ABI mismatch, not a VASP-specific secret:

1. MS-MPI's Fortran bindings expose `MPI_IN_PLACE` / `MPI_BOTTOM` through
   `/MPIPRIV1/` and `MPI_STATUSES_IGNORE` through `/MPIPRIV2/`. Both COMMON
   blocks expect **MSVC-style `DLLIMPORT`**, so Fortran uses the sentinel
   addresses recognized by MS-MPI's Fortran stubs.
2. **gfortran does not honor** that MSVC `DLLIMPORT` on those COMMONs the way
   MSVC / Intel Fortran do.
3. Fortran therefore passes `&mpipriv1_.mpi_in_place` (a normal process
   address) instead of the real C sentinel. Collectives that key off the
   sentinel then **corrupt memory** or return **wrong answers**.
4. The same mismatch passes local `mpipriv2_` to `mpi_waitall_`. MS-MPI does
   not recognize it as `MPI_STATUSES_IGNORE`, so C `MPI_Waitall` writes
   `count * MPI_STATUS_SIZE` integers into the small local COMMON. That
   overwrites adjacent BSS when several requests are pending.

References: [GCC Bug 47030](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=47030),
Stack Overflow [a/58123046](https://stackoverflow.com/a/58123046), MS-MPI /
MinGW Fortran interoperability discussions, Elmer's
`ELMER_BROKEN_MPI_IN_PLACE` notes.

Black-box confirmation: under gfortran + MS-MPI, `loc(MPI_IN_PLACE)` is a fake
local pointer; inplace `MPI_Allreduce` can return zeros while non-inplace
Allreduce is correct. Binary inspection also shows `m_waitall_` passing local
`mpipriv2_` as the status array.

### `/MPIPRIV2/` / `mpi_waitall_` / `MPI_STATUSES_IGNORE` (confirmed)

This is a **separate write-overflow path** from the `/MPIPRIV1/` IN_PLACE
sentinel remaps. Confirmed by binary inspection (`nm` / `objdump` / gdb
symbols) and validation A/B — not by reading proprietary VASP sources.

| Piece | Fact |
|---|---|
| Local COMMON | gfortran emits a process-local `/MPIPRIV2/` (`mpipriv2_`) for `MPI_STATUSES_IGNORE` |
| DLL COMMON | MS-MPI’s Fortran stub recognizes **only** the DLL import address (`*__imp_mpipriv2_`) |
| Failure mode | Local fake address is treated as a **writable** status array |
| Write size | C `MPI_Waitall` stores about `count * 20` bytes (`count` × Fortran status of 5 `INTEGER`s × 4 bytes) into that tiny COMMON |
| Collateral | Adjacent BSS is corrupted — observed victims include the named GOMP critical lock slot and `symm_`-related data |
| `/MPIPRIV1/` contrast | The short `mpipriv1_` struct has **no** direct write-overflow evidence of this kind; its bug is wrong sentinel identity for collectives |

**How it showed up on PBE0 (`bulk_BN_PBE0`, `-n 4`):**

1. Primary symptom was `GOMP_critical_name_start` → `libwinpthread` **SIGSEGV** after DAV / on the force path.
2. Replacing that named critical with a Win32 SRW lock (`VASP_GOMP_CRITICAL_WIN32=ON`, [`shim/gomp_critical_win32.c`](../shim/gomp_critical_win32.c)) **stopped the crash** but left **wrong forces / stress** — consistent with broader BSS corruption, not a broken lock implementation alone.
3. FFTW `libfftw3_omp` ↔ `libfftw3_threads` remaps and planner pins were useful hygiene; they are **not** the root cause of this crash or the numeric errors.

**Fix:** `__wrap_mpi_waitall_` remaps only local
`&mpipriv2_.mpi_statuses_ignore[0]` → `&__imp_mpipriv2_->mpi_statuses_ignore[0]`,
then calls `__real_mpi_waitall_`. See [`shim/msmpi_inplace_wrap.c`](../shim/msmpi_inplace_wrap.c).

**Verification (2026-07-21, native libgomp, `VASP_GOMP_CRITICAL_WIN32=OFF`):**

| Recipe | Ranks | Result |
|---|---|---|
| `bulk_BN_PBE0` | n=4 | **PASS** — energy, forces, and stress |
| `bulk_GaAs_ACFDT` | n=4 | **PASS** |

**SRW workaround demoted:** `VASP_GOMP_CRITICAL_WIN32` defaults to **OFF** in
[`build_pipeline.sh`](../build_pipeline.sh). The SRW shim remains available as a
**diagnostic** switch only; the WAITALL / `/MPIPRIV2/` remap is the real fix.

---

## What we changed (shim + pipeline)

### Files

| Path | Role |
|---|---|
| [`shim/msmpi_inplace_wrap.c`](../shim/msmpi_inplace_wrap.c) | GNU ld `--wrap` implementations: remap local fake COMMON addresses to MS-MPI DLL `mpipriv1_` / `mpipriv2_`, then call `__real_mpi_*_` |
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
mpi_gather_ mpi_alltoall_ mpi_alltoallv_ mpi_iallgather_ mpi_bcast_
mpi_waitall_ mpi_get_ blacs_gridinit_ blacs_gridmap_
```

Override with `MSMPI_WRAP_SYMS='...'` if `nm` on `vasp_std.exe` shows more
Fortran stubs that take `sendbuf` / `MPI_IN_PLACE`. Optional runtime tracing:
`MSMPI_WRAP_DEBUG=1`.

---

## Why it works

GNU ld `--wrap=mpi_foo_` redirects calls to `mpi_foo_` toward
`__wrap_mpi_foo_`.

Each wrapper:

1. Compares `sendbuf` (or origin for `mpi_get_`) to the **local** gfortran
   COMMON addresses `&mpipriv1_.mpi_in_place` / `&mpipriv1_.mpi_bottom`.
2. If equal, rewrites the pointer to the matching field in the **MS-MPI DLL**
   COMMON (`*__imp_mpipriv1_`), which is what the Fortran stubs actually test.
3. Calls the original MS-MPI Fortran stub `__real_mpi_*_` (not the C
   `MPI_*` + `MPI_Type_f2c` path). That keeps Fortran datatype / op / comm
   handles intact — the C+f2c path can report `MPI_DATATYPE_NULL` for some
   MS-MPI Fortran handle encodings (seen on ACFDT-style workloads).

`mpi_waitall_` follows the same address-remap rule for the status argument:
only local `&mpipriv2_.mpi_statuses_ignore[0]` is replaced with the matching
DLL COMMON address (`*__imp_mpipriv2_`). Count, request array, and `ierr` are
forwarded unchanged. Without that remap, MS-MPI writes roughly `count * 20`
bytes of statuses into the tiny local COMMON and corrupts adjacent BSS.

MS-MPI’s Fortran layer then sees the DLL sentinel it expects. No gfortran
rebuild and no proprietary VASP edits are required.

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
- `mpi_bcast_` (NULL-dt fallback only; no IN_PLACE sendbuf)
- `mpi_waitall_` (`MPI_STATUSES_IGNORE` via `/MPIPRIV2/`)
- `mpi_get_` (RMA origin may use `MPI_BOTTOM`)

**Not wrapped by default** (non-exhaustive): other collectives / RMA /
neighborhood collectives (`mpi_scatter*`, `mpi_reduce_scatter*`, `mpi_put_`,
`mpi_accumulate_`, nonblocking variants beyond `iallgather` / blocking
`bcast`, etc.). If a future workload crashes or disagrees across rank counts,
inspect Fortran MPI stubs with `nm` and extend `MSMPI_WRAP_SYMS` plus matching
`__wrap_*` / `__real_*` declarations in `shim/msmpi_inplace_wrap.c`.

Other limits:

- Fix is for **gfortran + MS-MPI**. Intel MPI packages do not need this shim.
- Older portable ZIPs built **without** the shim remain unsafe for multi-rank
  MS-MPI; rebuild with current `build_pipeline.sh`.
- The shim does not replace a correct compiler / `DLLIMPORT` fix upstream; it is
  a practical link-time workaround.

---

## Develop rebuild (no ZIP)

For shim iteration after one full `release` unpack:

```bash
VASP_PIPELINE_MODE=develop VASP_TARBALL=/c/path/to/vasp.tgz bash build_pipeline.sh
# or: bash build_pipeline.sh --develop /c/path/to/vasp.tgz
cp -f build_work/vasp.*/build/bin/vasp_*.exe build_work/vasp-*-msys2-portable/bin/
```

`develop` never `rm -rf build_work`; it skips harvest/package/zip.

## Single validation recipes

Upstream: [Validation tests](https://vasp.at/wiki/Validation_tests) —
`VASP_TESTSUITE_TESTS=bulk_GaAs_ACFDT` then `make test`, or `./runtest` with a
config. This repo:

```bash
bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT
bash toolchain/run_testsuite.sh --fast bulk_BN_PBE0
```

Bare `bash toolchain/run_testsuite.sh` (no recipe names) runs the **entire FAST
category** — avoid that while debugging one failure. Do not run concurrent
`--fast` instances.

## Track split (keep these separate)

Independent failure classes on the same FAST portable. Do **not** conflate them:

| Track | Typical recipes | Symptom | What helps |
| --- | --- | --- | --- |
| **MPI / ACFDT (NULL dt)** | `bulk_GaAs_ACFDT`, `HEG_333_LW`, `SiC_ACFDTR_T`, `SiC8_GW0R` (+ related ACFDT/GW paths) | `MPI_Allreduce` / `MPI_Bcast` abort with **`MPI_DATATYPE_NULL`** | This shim: IN_PLACE remap + shared NULL-dt fallback on `mpi_allreduce_` / `mpi_bcast_` (BLACS TopsRepeat is optional opt-in only) |
| **BLACS TopsRepeat SEGV** | `LiH_MLFF_8atoms`, `C8_no_symm_BSE` (n≥2) | SIGSEGV in `libscalapack` via `__wrap_blacs_gridinit_` / `gridmap_` → `blacs_set_(TopsRepeat)` when TopsRepeat was forced by default | **Default: TopsRepeat off** (unset/`0`). Opt in with `MSMPI_BLACS_TOPSREPEAT=1` only for diagnosis; ACFDT n=4 PASS does **not** require it |
| **MPI / WAITALL (`/MPIPRIV2/`)** | `bulk_BN_PBE0` (and other multi-request wait paths) | SIGSEGV in `GOMP_critical_name_start` → `libwinpthread`, or wrong forces/stress after SRW-only workaround | `__wrap_mpi_waitall_` + `__imp_mpipriv2_` remap (see above). **Not** fixed by NULL-dt fallback or FFTW omp↔threads alone |
| **FFT hygiene (secondary)** | hybrid OpenMP jobs | Planner / thread-pool noise | FFTW planner ctor + pins — see below; useful but **not** the PBE0 n4 root cause |

---

## Further mitigation: NULL datatype on ACFDT / Bcast (2026-07-21)

This is a **runtime mitigation**, not an upstream root-cause fix. The caller
still passes `MPI_DATATYPE_NULL` into Fortran `mpi_allreduce_` and/or
`mpi_bcast_` on some multi-rank ACFDT / HEG / SiC paths; the wrap substitutes a
usable MS-MPI datatype so the collective can complete.

### Evidence (debug — do not re-guess)

With `MSMPI_WRAP_DEBUG=1` passed through `mpiexec -env` on the current portable
`vasp_std` (linked with `__real_mpi_*_` wraps):

| Observation | Meaning |
| --- | --- |
| Many `[wrap] mpi_allreduce_: fake → DLL mpipriv1` lines | Fortran `--wrap` **is** linked; **IN_PLACE remap succeeds** |
| Healthy remapped calls: `datatype≈MPI_DOUBLE_PRECISION`, `op≈MPI_SUM` | Normal Fortran collectives |
| Failing instant: still enters `__wrap_mpi_allreduce_`, IN_PLACE already remapped, but **`datatype=MPI_DATATYPE_NULL`**, `op` is a **user** op from `mpi_op_create_` | Abort is **not** a missed IN_PLACE remap; the handle is already NULL at the wrap |
| `VASP_TESTSUITE_NRANKS=1` | **PASS** without NULL-dt fallback (bad multi-rank reduce path unused) |
| Default n=4 + NULL → `MPI_DOUBLE_COMPLEX` substitute | **`bulk_GaAs_ACFDT` PASS** (energies match reference) |

ScaLAPACK/BLACS C `MPI_Allreduce` + `MPI_Op_create` is a separate code path;
once the Fortran NULL-dt case is handled, it was not the ACFDT abort.

### Mitigation mechanism

1. **IN_PLACE remap** (existing): local gfortran `/MPIPRIV1/` → MS-MPI DLL `mpipriv1_`.
2. **NULL / `MPI_DATATYPE_NULL` fallback** via shared `null_dt_fallback()` on
   `__wrap_mpi_allreduce_` and `__wrap_mpi_bcast_`: if `*datatype` is `0` or
   `MPI_DATATYPE_NULL`, pass a **local** substitute handle into `__real_mpi_*_`
   (does **not** write through the caller’s pointer). `mpi_bcast_` has no
   IN_PLACE sendbuf — only this NULL-dt path. Default substitute: Fortran
   `MPI_DOUBLE_COMPLEX`.
   - Env: `MSMPI_NULL_DT_FALLBACK=double|byte|none`
   - `double` → `MPI_DOUBLE_PRECISION`; `byte` → `MPI_BYTE`; `none` keeps NULL
     (MS-MPI will still error — useful to confirm the mitigation is required).
3. **Optional BLACS TopsRepeat (default OFF)**: `--wrap=blacs_gridinit_` /
   `blacs_gridmap_` may call `blacs_set_(ctxt, 15, 1)` so BLACS `gsum2d`
   prefers tree topology (avoids some BLACS C `MPI_Allreduce` +
   `MPI_DATATYPE_NULL` paths). **Default is off** (unset / `0` / empty).
   Historically, forcing TopsRepeat after every grid init/map SIGSEGV’d inside
   `libscalapack` on MLFF / BSE (stack: `blacs_force_tops_repeat` →
   `blacs_set_`). Opt in only for diagnosis: `MSMPI_BLACS_TOPSREPEAT=1`
   (writes `msmpi_blacs_tops_repeat.log` when applied). Invalid / negative
   `ctxt` is skipped even when opted in. ACFDT multi-rank PASS relies on the
   NULL-dt fallback above, not on TopsRepeat (confirmed n=4 with default off).

### How to enable debug

```bash
# Via testsuite overlay / mpiexec env (example):
mpiexec -n 4 -env MSMPI_WRAP_DEBUG 1 -env OMP_NUM_THREADS 1 ... vasp_std.exe
# MSMPI_WRAP_DEBUG unset/0 → off (mere presence of the var must NOT enable)
# MSMPI_WRAP_DEBUG=1  → rank 0 only; NULL-dt / BAD always; remaps rate-limited
# MSMPI_WRAP_DEBUG=2  → rank 0 only; every wrapped call (still line-atomic)
```

`toolchain/run_testsuite.sh` + overlays forward `MSMPI_WRAP_DEBUG` through
`mpiexec -env` when set. Prefer **unset** for normal validation — older shim
debug used unlocked multi-rank `fprintf` and produced ~3M interleaved
single-character lines, which made SUMMARY false-FAIL even when E/F/S matched.

Look for:

- `[wrap] mpi_allreduce_: fake → DLL mpipriv1` (rate-limited at level 1)
- `[wrap] mpi_allreduce_: NULL datatype -> 0x... (count=... op=...)`
- `[wrap] mpi_bcast_: NULL datatype -> 0x... (count=...)`
- `[wrap] mpi_waitall_: ... (DLL mpipriv2)` (rate-limited at level 1)
- optional `[wrap] blacs TopsRepeat set=1 ...` (only if `MSMPI_BLACS_TOPSREPEAT=1`)

### Limits / risks

- **Not a root-cause fix**: something upstream still hands `MPI_DATATYPE_NULL`
  into Allreduce (user `MPI_Op`) and/or Bcast on multi-rank ACFDT / HEG / SiC
  paths. The shim only unblocks MS-MPI so validation can proceed.
- Fallback assumes the buffer layout matches the chosen substitute
  (`MPI_DOUBLE_COMPLEX` by default). Wrong size/type could corrupt memory or
  yield wrong energies — treat PASS as “validated for known recipes”, not a
  proof of general correctness for every NULL-dt call site.
- NULL-dt fallback applies to `mpi_allreduce_` and `mpi_bcast_` today; other
  collectives still only remap IN_PLACE/BOTTOM (where applicable).
  `mpi_ibcast_` is **not** wrapped unless a future log shows that path.
- Older portable ZIPs without this wrap object remain broken on multi-rank
  ACFDT / HEG / SiC Bcast; rebuild / copy a current `vasp_std.exe` into the
  portable `bin/`.

### Bcast NULL-dt (closed 2026-07-21)

Previously open: **HEG_333_LW**, **SiC_ACFDTR_T**, **SiC8_GW0R** aborted with
**MPI_Bcast + MPI_DATATYPE_NULL**. Closed by extending the shared
`null_dt_fallback` helper to `__wrap_mpi_bcast_` and adding `mpi_bcast_` to
`MSMPI_WRAP_SYMS` (same default-type assumption / risk as Allreduce; still a
mitigation, not an upstream root-cause fix). Companion history:
[MSYS2_MSMPI_MULTIRANK.md](MSYS2_MSMPI_MULTIRANK.md).

**Verification (develop relink, unset `MSMPI_WRAP_DEBUG`):**

| Recipe | Result |
|---|---|
| `HEG_333_LW` | **PASS** |
| `SiC_ACFDTR_T` | **PASS** |
| `SiC8_GW0R` | **PASS** |
| `bulk_GaAs_ACFDT` (regression) | **PASS** |
| `bulk_BN_PBE0` (regression) | **PASS** |

**WRAP_DEBUG smoke (`MSMPI_WRAP_DEBUG=1`, `HEG_333_LW`):** **PASS**; ~11k readable
lines (not million-line char garble); includes
`[wrap] mpi_bcast_: NULL datatype -> ...` and allreduce NULL-dt lines.

### Confirmed status (uncommitted)

- `bulk_GaAs_ACFDT` at default FAST ranks (**n=4**): **PASS** (IN_PLACE + NULL-dt
  path; still true after WAITALL + Bcast wraps).
- `bulk_BN_PBE0` at **n=4**: **PASS** energy/forces/stress with
  `__wrap_mpi_waitall_` + `__imp_mpipriv2_` remap and **native GOMP**
  (`VASP_GOMP_CRITICAL_WIN32=OFF`).
- `HEG_333_LW` / `SiC_ACFDTR_T` / `SiC8_GW0R`: **PASS** after `__wrap_mpi_bcast_`
  NULL-dt fallback (`nm` shows `__wrap_mpi_bcast_` / `null_dt_fallback`).
- Changes live in `shim/msmpi_inplace_wrap.c` + `build_pipeline.sh` wrap list /
  GOMP default; **not committed** at the time of this note.

### OpenMP / hybrid notes (PBE0, 2026-07-21)

Probe (`omp_get_max_threads` under Scoop MS-MPI 10.1): overlay
`mpiexec -env OMP_NUM_THREADS 1` **works**. VASP banner at default FAST ranks:
`4 mpi-ranks, with 1 threads/rank`.

| Launch | Result (before `/MPIPRIV2/` waitall wrap) |
| --- | --- |
| `-n 1` + `OMP_NUM_THREADS=1` | **PASS** (energies/forces/stress) |
| `-n 4` + `OMP_NUM_THREADS=1` | **SIGSEGV** in `GOMP_critical_name_start` → `libwinpthread` (often framed as after DAV / `fock_force` / FFT planner) |

So this was **not** “n4 × OMP>1”. Recommended pins remain per-rank
`OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1` (also `OMP_DYNAMIC=FALSE`,
`OMP_MAX_ACTIVE_LEVELS=1`).

**Root cause (resolved):** local `/MPIPRIV2/` `MPI_STATUSES_IGNORE` →
`mpi_waitall_` write overflow into adjacent BSS (GOMP lock / `symm_`). See the
`/MPIPRIV2/` subsection under [Root cause](#root-cause) above. After
`__wrap_mpi_waitall_` + `__imp_mpipriv2_` remap, **native GOMP** (no SRW)
passes `bulk_BN_PBE0` n4 energy/forces/stress; `bulk_GaAs_ACFDT` n4 still
passes.

**SRW diagnostic only:** `VASP_GOMP_CRITICAL_WIN32` defaults to **OFF**. Setting
it ON (`shim/gomp_critical_win32.c`) previously masked the SIGSEGV but left
wrong forces/stress — evidence the lock was a collateral victim, not the bug.

Secondary hygiene applied so far (source-free; **not** the main fix):

1. Remap FFTW **link** `libfftw3_omp` → `libfftw3_threads` (see
   `shim/cmake_fftlib_win32_inject.cmake`); harvest omits the omp DLL;
   `run_testsuite.sh` drops PATH entries that host `libfftw3_omp*`.
2. Planner ctor + `--wrap` of `dfftw_plan_with_nthreads*` /
   `dfftw_init_threads*` (`shim/fftw_planner_thread_safe.c`); default
   `VASP_FFTW_MAX_THREADS=1` skips the FFTW thread pool (raise to re-enable).
3. Early gdb stacks showed `fock_force` → FFT → `libwinpthread` with
   `libfftw3_threads` loaded; binary also showed `GOMP_parallel` /
   `GOMP_critical` near planner symbols. Those stacks were **symptoms** of
   corrupted lock state after WAITALL overflow, not proof that FFTW omp was
   the root cause.

**A/B (pre-WAITALL fix, source-free):** `VASP_FFTLIB=OFF` develop rebuild
(`CMakeCache` `VASP_FFTLIB:BOOL=OFF`, no `fftlib` symbols in `nm`) **still
SIGSEGVd** on `bulk_BN_PBE0` at `-n4`. So the crash was **not unique to the
fftlib dynamic-loader path**. `build_pipeline.sh` still accepts
`VASP_FFTLIB=ON|OFF` (default ON) for experiments.

Do **not** treat forcing serial FFTW / `fftw_mingw_serial_stub.c` as the primary
fix; that stub remains experimental and unlinked by default.

`run.bat` now passes the same pins via `mpiexec -env` (not only `set` in the
parent shell).

## Policy

Aligned with [AGENTS.md](../AGENTS.md): do not commit ZIPs / `build_work/` /
tarballs / `POTCAR`; do not push unless asked; do not load proprietary VASP
sources into review context when debugging this class of issue.
