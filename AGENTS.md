# Agent instructions (vasp-windows-msys2-build)

This file is for AI coding agents (e.g. Cursor). Human-facing docs live in `README.md` and `docs/`.

## Repo purpose

Portable MSYS2/UCRT64 **build scripts and packaging** for VASP on Windows. This repository does **not** ship VASP source code. Users supply their own licensed VASP tarball at build time.

## Hard bans

- **Never** read, search, open, unpack, or dump into context:
  - user VASP tarballs (`*.tar.gz`, `*.tgz`, `vasp*.zip`, and similar)
  - `build_work/` trees or any extracted upstream source under the work directory
  - `potpaw*` archives, `POTCAR`, or other pseudopotential / licensed potential files
- **Never** commit or `git push` build artifacts or licensed materials, including:
  - portable ZIPs (`*.zip`), `build_work/`, VASP tarballs, `POTCAR` / potpaw
  - This repo typically has **no remotes configured**. Do **not** add a remote or push unless the user **explicitly** asks.
- **Never** casually modify content inside the `vasp_cmake/` submodule. Bump the submodule pin only when the user **explicitly** requests it.

## Allowed work

- Root `build_pipeline.sh` and related packaging scripts
- `patches/` (Windows/MSYS2 build fixes; keep changes minimal and documented)
- English documentation (`README.md`, `STEP_BY_STEP.md`, `CONTRIBUTING.md`, `docs/`)
- Future thin `toolchain/` wrappers (env / deps entry points that call `build_pipeline.sh`)

## Build protocol

When the user **explicitly authorizes** a build:

1. Run the pipeline via shell (e.g. `bash build_pipeline.sh` under UCRT64).
2. Inspect **logs, compiler errors, exit codes, and ZIP listings** only.
3. Do **not** open or search VASP Fortran/C++ sources from the extracted tree into agent context.

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
