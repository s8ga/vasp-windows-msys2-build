# Agent instructions (vasp-windows-msys2-build)

This file is for AI coding agents (e.g. Cursor). Human-facing docs live in `README.md` and `docs/`.

## Repo purpose

Portable MSYS2/UCRT64 **build scripts and packaging** for VASP on Windows. This repository does **not** ship VASP source code. Users supply their own licensed VASP tarball at build time.

## Hard bans

- **Never** read, search (including grep/rg/Select-String), open, unpack, or dump into context:
  - user VASP tarballs (`*.tar.gz`, `*.tgz`, `vasp*.zip`, and similar)
  - **any** content under `build_work/` that is upstream/extracted source — including `*.F`, `*.f90`, `*.hpp`, `src/**`, and fftlib headers (headers count; “no Fortran hit” is still a violation)
  - `potpaw*` archives, `POTCAR`, or other pseudopotential / licensed potential files
- **Stop-and-ask:** if you believe reading any `build_work/` upstream file is required, **stop**, state what and why, and wait for **explicit user approval**. Do not search or read first.
- **Never** commit or `git push` build artifacts or licensed materials, including:
  - portable ZIPs (`*.zip`), `build_work/`, VASP tarballs, `POTCAR` / potpaw
  - This repo typically has **no remotes configured**. Do **not** add a remote or push unless the user **explicitly** asks.
- **Never** casually modify content inside the `vasp_cmake/` submodule. Bump the submodule pin only when the user **explicitly** requests it.

## Allowed work

- Root `build_pipeline.sh` and related packaging scripts
- `patches/` (Windows/MSYS2 build fixes; keep changes minimal and documented)
- English documentation (`README.md`, `STEP_BY_STEP.md`, `CONTRIBUTING.md`, `docs/`)
- Future thin `toolchain/` wrappers (env / deps entry points that call `build_pipeline.sh`)
- Binary/debug inspection **without** reading source: `nm` / `objdump` / `ntldd` / `strings` on `*.exe`/`*.dll`; gdb **symbol names**; build/test logs and exit codes

## Build protocol

When the user **explicitly authorizes** a build:

1. Run the pipeline via shell (e.g. `bash build_pipeline.sh` under UCRT64).
2. Inspect **logs, compiler errors, exit codes, and ZIP listings** only.
3. Do **not** open or search VASP Fortran/C++/header sources from the extracted tree into agent context (see stop-and-ask above).

```text
# GOOD — authorized build
bash build_pipeline.sh
# then read build logs / exit status / artifact listing only
```

## Submodule

- `vasp_cmake` → `https://github.com/vasp-dev/cmake.git` @ branch/track `6.6.x`
- Clone with: `git clone --recurse-submodules …`

## Environment assumptions

- MSYS2 **UCRT64** environment
- Scoop-installed MSYS2 and MS-MPI are acceptable
- User-facing documentation in this repo is **English only**
