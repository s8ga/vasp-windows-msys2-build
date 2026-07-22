# Win32 BSE / QPBSE guards (`src/bse.F`)

English reference for the **BSE-related patches** shipped in this repo for
MSYS2 UCRT64 gfortran + MS-MPI portable builds. Build-glue only: symptoms and
patch intent are described from patch comments and validation logs — proprietary
VASP sources are not quoted here.

Related: [WIN32_MAXMEM.md](WIN32_MAXMEM.md), [MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md),
[README.md](../README.md).

---

## Problem (black-box)

On native Windows PE builds, some **QPBSE / LQP** (`N_GW`) validation paths
entered the older `CALCULATE_BSE` matrix driver with defaults that skipped
allocation of `AMAT` / `AVpW` (and related arrays), then still zeroed or
deallocated them. Under MS-MPI multi-rank that showed up as:

- `memset`-style **SIGSEGV** on unallocated `AVpW*` / `BVpW*` zeroing
- later **DEALLOCATE** of never-allocated `AMAT` (and related) crashes

These are **Win32 / MS-MPI validation guards**, not physics changes. Ordinary
BSE recipes that already allocate correctly are unaffected by the ALLOCATED
guards; the IBSE force applies only inside the **LQP / QPBSE** branch.

---

## Patches

| Patch | Target | What it does |
| ----- | ------ | ------------ |
| [`patches/0005-bse-guard-avpw-zeroing.patch`](../patches/0005-bse-guard-avpw-zeroing.patch) | `src/bse.F` | Under `LQP`, zero `AVpW` / `AVpW_SCALA` / `BVpW` / `BVpW_SCALA` only when **`ALLOCATED(...)`** (mirrors existing `VMAT` guards) |
| [`patches/0006-bse-lqp-force-ibse0.patch`](../patches/0006-bse-lqp-force-ibse0.patch) | `src/bse.F` | Inside the **QPBSE / LQP** path, if `IBSE /= 0`, force **`IBSE=0`** (old matrix driver) and print `QPBSE/LQP: forcing IBSE=0 (old matrix driver)` |

### Why `IBSE=0` on QPBSE / LQP

Upstream chi defaults can leave `IBSE=2` (newer BSE driver) for ordinary BSE,
while **QPBSE still enters the older matrix path**. That older path allocates
`AMAT` / `AVpW` and runs SELFEN only when `IBSE==0` (matches reference OUTCAR
expectations for QPBSE). Leaving `IBSE=2` skips allocation and then crashes on
deallocate / unallocated zeroing — observed on **`N_GW` QPBSE**.

`0006` forces the old driver **only** in that LQP branch. It does not change
default IBSE for non-LQP BSE.

### Why ALLOCATED guards (`0005`)

Even with correct IBSE, LQP zeroing can still run when arrays were never
allocated (wrong branch / `ANIRES`). Guarding with `ALLOCATED` avoids
`memset(NULL, …)` SIGSEGV on `N_GW` QPBSE.

---

## Build integration

`build_pipeline.sh` stage **patch** applies `0005` and `0006` idempotently
(marker substrings already present → skip) and **dies** if either marker is
missing after apply:

```text
IF (ALLOCATED(AVpW)) AVpW=0
QPBSE/LQP: forcing IBSE=0
```

They are listed next to the timing / MAXMEM patches (`0001` / `0002` / `0004`).
`0003` (DFTD4 CMake enable) is applied earlier when staging `cmake/`, not in
this Fortran patch loop — see [DESIGN.md](DESIGN.md).

---

## Verification (source-free)

After a rebuild (release or develop + relink), run the licensed testsuite
recipe(s) that exercise QPBSE / `N_GW` via
[`toolchain/run_testsuite.sh`](../toolchain/run_testsuite.sh). Expect exit 0
and matching SUMMARY energies — do not open extracted `src/bse.F` in review
context; use logs and exit codes only ([AGENTS.md](../AGENTS.md)).

Companion MPI issues on other FAST recipes (ACFDT NULL-dt, WAITALL
`/MPIPRIV2/`, BLACS TopsRepeat) are separate tracks — see
[MSMPI_INPLACE_SHIM.md](MSMPI_INPLACE_SHIM.md).
