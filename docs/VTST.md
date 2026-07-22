# Optional VTST (transition-state tools)

This repository can optionally overlay **VTST** (Henkelman group
[vtstcode](https://theory.cm.utexas.edu/vtsttools/)) into a licensed VASP 6.6.x
tree before CMake configure. Default builds remain **stock** (no VTST).

**This repo does not ship vtstcode.** Obtain it either via the optional
toolchain fetch (`install_vtst.sh`) or by unpacking upstream yourself, then
point `VTST_CODE_DIR` at that tree (or source `toolchain/install/setup_vtst`).

VTST source is distributed under the **Apache License 2.0**. Respect that
license (and your VASP license) when combining, redistributing binaries, or
publishing derived packages.

## Fetch vtstcode (optional)

Pinned commit + SHA256 live in `toolchain/package_versions.sh`. Source-only
(no compile); installs under `toolchain/install/vtst-<ver>/vtstcode6.6.0/` and
writes `setup_vtst` exporting `VTST_CODE_DIR` (does not override a pre-set
value). Not in the default `OPTIONAL_LIBS` list.

```bash
# UCRT64, from repo root
bash toolchain/scripts/install_vtst.sh
# or: OPTIONAL_LIBS="hdf5 libxc wannier90 dftd4 vtst" bash toolchain/scripts/install_optional.sh
source toolchain/install/setup_vtst   # or: source toolchain/install/setup
```

## Quick enable

```bash
# UCRT64 — after deps + VASP_TARBALL are set
export VASP_VTST=ON
# After install_vtst.sh, sourcing setup_vtst is enough; or set manually:
export VTST_CODE_DIR='/c/path/to/vtstcode6.6.0'   # dir that contains chain.F
bash toolchain/build_vasp.sh
# or: bash build_pipeline.sh
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `VASP_VTST` | `OFF` | `ON` → flavor `vtst`, inject after patch, artifact name gets `-vtst` |
| `VTST_CODE_DIR` | *(empty)* | Required when `ON`. Unpacked vtstcode root (or a parent that contains `vtstcode6.6.0/`) |

`OFF` (default) never touches VTST paths and never injects into a stock tree.

Convenience: set the same exports in `toolchain/local.env` (see
`toolchain/local.env.example`).

## What inject does (v1)

Script: [`toolchain/scripts/inject_vtst.sh`](../toolchain/scripts/inject_vtst.sh).

When `VASP_VTST=ON` the pipeline runs it **after** Win32/BSE patches and
**before** CMake configure (release and develop):

1. Backup stock `src/chain.F` → `src/chain.F.pre_vtst` (once)
2. Copy **all** core `*.F` from `VTST_CODE_DIR` over `src/` (including `ml_pyamff.F`)
3. Copy `pyamff_fortran/` into `src/pyamff_fortran/` and install the CMake overlay
   from `cmake_overlays/CMakeLists_pyamff_fortran.txt`
4. Patch `src/main.F` (TSIF in `CHAIN_FORCE`; unconditional `chain_init`)
5. Insert VTST core objects into `src/.objects` before `chain.o`
   (includes `ml_pyamff.o` before `opt.o`; **not** `pyamff_fortran/*.o`)
6. Patch staged `cmake/CMakeLists/CMakeLists_src.txt`:
   `add_subdirectory(pyamff_fortran)` + `PRIVATE` link +
   `Fortran_MODULE_DIRECTORY` include + `add_dependencies(… pyamff_fortran)` for
   `vasp_std` / `gam` / `ncl`; then sync to materialized `src/CMakeLists.txt` on
   Windows when that file is a real copy (not a symlink)

**Not in v1:**

- No makefile edits (CMake build path only)

You can also run the inject script alone against an already-unpacked tree:

```bash
VASP_VTST=ON SRC_ROOT=/path/to/vasp.6.6.0 \
  VTST_CODE_DIR=/path/to/vtstcode6.6.0 \
  bash toolchain/scripts/inject_vtst.sh
```

## Dual work trees (stock vs vtst)

Each **release** creates a **new** stamp directory. Stock and VTST never share
a work tree:

```text
build_work/
  stock/
    20260722-220015/     # one release
    CURRENT              # one line: absolute path of latest successful stock release
  vtst/
    20260722-221530/
    CURRENT
```

| Mode | Work directory |
| --- | --- |
| `release` | New `build_work/<flavor>/<stamp>/` (`YYYYMMDD-HHMMSS`) |
| `develop` | Path from `build_work/<flavor>/CURRENT` (or explicit `WORK_DIR`) |

- `flavor` = `vtst` when `VASP_VTST=ON`, else `stock`.
- Explicit `WORK_DIR=...` always wins (advanced; no automatic stamp).
- Old stamps are **not** auto-deleted — remove unused directories yourself.
- Never inject VTST into a stock tree; keep flavors separate.

## Artifact names (`-vtst`)

All portable outputs follow `PKG_NAME`. When `VASP_VTST=ON`, the pipeline
**appends** `-vtst` if the name does not already end with it:

| `VASP_VTST` | Directory / ZIP (default) |
| --- | --- |
| `OFF` | `vasp-6.6.0-msys2-portable` / `.zip` / `.zip.sha256` |
| `ON` | `vasp-6.6.0-msys2-portable-vtst` / `.zip` / `.zip.sha256` |

Do not ship an unmarked ZIP that was built with VTST — the `-vtst` suffix is
intentional so users can tell the flavors apart.

## vs typical HPC `+vtst` packages

| HPC-style `+vtst` | This repo |
| --- | --- |
| Variant default OFF | `VASP_VTST=OFF` |
| Fetches vtstcode as a resource | Optional `install_vtst.sh` pin, or **you** set `VTST_CODE_DIR` |
| Overlay + `.objects` / `main.F` | Same idea via `inject_vtst.sh` |
| May bundle PyAMFF | **v1 includes PyAMFF** (`ml_pyamff.F` + `pyamff_fortran` CMake lib) |
| Single stage tree | Per-release stamp + **stock / vtst** separation |

## License reminder

- **VTST / vtstcode:** Apache License 2.0 (upstream).
- **VASP:** proprietary — your license covers source and calculations.
- **This repo’s glue** (scripts, patches, docs): [MIT](../LICENSE).

## Running the testsuite

`toolchain/run_testsuite.sh` resolves a **generic build flavor** (not only
stock/vtst). Order: `env_ucrt64` (+ `local.env`) → flavor / `PKG_NAME` → paths.

| Knob | Role |
| --- | --- |
| `VASP_BUILD_FLAVOR` | Primary: `build_work/<flavor>/CURRENT` + package name (default `stock`) |
| `VASP_VTST=ON` / `OFF` | Convenience when flavor unset → `vtst` / `stock` |
| `PKG_NAME` | Optional exact package dir name under the stamp |
| `VASP_PORTABLE_BIN` | Wins over all discovery |

`VASP_VTST=ON` with a non-`vtst` `VASP_BUILD_FLAVOR` is a **conflict** (runner
exits with an error). Prefer `VASP_BUILD_FLAVOR` for new schemes; keep
`VASP_VTST=ON` as a VTST shortcut. Set the same knobs in `toolchain/local.env`
(they are sourced **before** flavor resolution).

**Package name convention:** `stock` → `…-msys2-portable`; any other flavor →
`…-msys2-portable-<flavor>` (**exact only** — no silent fallback to a different
`…-portable*`). Stock (including the default) never auto-adopts a sole
`…-portable-<other>` under CURRENT. New schemes only need
`build_work/<name>/CURRENT` plus a matching portable directory (or set
`PKG_NAME` / `VASP_PORTABLE_BIN`). Mismatched packages under CURRENT → **die**
listing candidates. Bin vs testsuite from different stamps → loud warning.

The official suite is still a **DFT regression** harness — it does **not**
exercise VTST transition-state features.

```bash
# Stock (default) — build_work/stock/CURRENT
bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT

# Generic flavor knob (recommended for non-stock schemes)
VASP_BUILD_FLAVOR=vtst bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT

# VTST convenience alias
VASP_VTST=ON bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT

# Explicit bin override (wins over CURRENT)
VASP_PORTABLE_BIN='/c/path/to/vasp-*-msys2-portable-vtst/bin' \
  bash toolchain/run_testsuite.sh --fast bulk_GaAs_ACFDT

# Resolve-only smoke (print flavor / bin / testsuite paths; no runtest)
TESTSUITE_RESOLVE_ONLY=1 VASP_BUILD_FLAVOR=vtst bash toolchain/run_testsuite.sh
```

## Acceptance checks

Useful after a first VTST-enabled build (inspect **directories / ZIP names /
logs** only — do not commit `build_work/` or vtstcode):

1. Two consecutive **stock** releases → two stamp dirs under
   `build_work/stock/`; `CURRENT` points at the second.
2. A **VTST** release (`VASP_VTST=ON`) lands only under `build_work/vtst/…`
   and produces `…-msys2-portable-vtst.zip` (+ `.sha256`). Stock stamps stay
   untouched (VTST is never injected into a stock tree).
3. `develop` with `VASP_VTST=ON` (and `VTST_CODE_DIR`) rebuilds the path in
   `build_work/vtst/CURRENT` (or an explicit `WORK_DIR`).
4. Default `VASP_VTST=OFF` keeps the previous stock path and ZIP name
   (`vasp-6.6.0-msys2-portable.zip` with no `-vtst`).
5. Portable `run.bat`: `cd` to a job folder that has `INCAR`, then call the bat
   by absolute or relative path. Missing `INCAR` → error and `exit /b 1`.
