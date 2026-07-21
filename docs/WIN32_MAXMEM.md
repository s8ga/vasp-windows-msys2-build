# Windows MAXMEM auto-detect (`AUTOSET_AVAILABLE_MEMORY`)

## Problem

As of VASP 6, `MAXMEM` defaults to **~90% of available RAM per MPI rank**,
estimated by reading Linux `/proc/meminfo` (`MemAvailable:`). On **native
Windows PE** binaries (MSYS2 UCRT64 `vasp_*.exe` launched by MS-MPI
`mpiexec`), that file does not exist. `INQUIRE` fails → `IERROR ≠ 0` → tutor
alert and the hard-coded default **2800 MB** is kept:

```text
Failed to automatically set available memory for this job...
default value of 2800 MB might be grossly inefficient.
```

Linux and WSL builds that see a real `/proc/meminfo` are unchanged.

## Fix (this repo)

| Piece | Role |
| ----- | ---- |
| [`shim/win32_available_memory.c`](../shim/win32_available_memory.c) | `GlobalMemoryStatusEx` → available physical RAM in **kB** |
| [`patches/0004-autoset-available-memory-win32.patch`](../patches/0004-autoset-available-memory-win32.patch) | In `src/ini.F` `AUTOSET_AVAILABLE_MEMORY`: if `/proc/meminfo` is missing, call the C helper via `ISO_C_BINDING` |
| [`shim/cmake_win32_mem_inject.cmake`](../shim/cmake_win32_mem_inject.cmake) | Link the helper object into `vasp_std` / `vasp_gam` / `vasp_ncl` only |

Semantics after a successful query match upstream:

1. Available memory in kB (WinAPI `ullAvailPhys / 1024`, or Linux `MemAvailable`)
2. Divide by **intra-node** MPI ranks
3. MPI sync: take the **minimum** across nodes
4. Set `MAXMEM` to **90%** of that value (MB)
5. Print `available memory per node: … GB, setting MAXMEM to …`

Manual `MAXMEM` in `INCAR` still overrides / disables auto-estimation as
documented on the [VASP Wiki](https://vasp.at/wiki/MAXMEM).

## Build integration

`build_pipeline.sh` applies `0004` idempotently in stage **patch**, compiles
the C object next to the other shims, and passes
`-DVASP_WIN32_MEM_OBJ=…` plus the CMake inject via
`CMAKE_PROJECT_TOP_LEVEL_INCLUDES`.

## Verify

After a rebuild (release or develop + recompile `ini.F` / relink):

1. Run any short job **without** `MAXMEM` in `INCAR`.
2. Expect **no** `AUTOSET_MEM` tutor alert.
3. Expect a line like:
   `available memory per node:   xx.xx GB, setting MAXMEM to     NNNNN`
4. Optional: set `MAXMEM = 2800` in `INCAR` and confirm auto-detect is skipped.

Do **not** rely on MSYS2 `/proc` for native PE; the WinAPI path is authoritative
on Windows.
