# VASP 6.6.x — Windows Portable Build (MSYS2 / UCRT64)

One-command pipeline that turns a **licensed VASP source tarball** (obtained by
you) into a **portable ZIP** containing `vasp_std` / `vasp_gam` / `vasp_ncl`,
runtime DLLs, the MS-MPI launcher, and a simple `run.bat`.

Toolchain (open source + Microsoft MPI):

```text
gfortran (UCRT64) + MS-MPI + OpenBLAS + ScaLAPACK(msmpi) + FFTW + OpenMP + fftlib + HDF5
```

**This repository does not ship VASP source code, POTCAR files, or prebuilt
binaries.** You must provide your own licensed VASP tarball outside this repo.

---

## 1. What this is


| Item                  | Role                                                               |
| --------------------- | ------------------------------------------------------------------ |
| `build_pipeline.sh`   | **Single source of truth** — one-command driver (preflight → zip)  |
| `toolchain/`          | Thin English entry points (deps / env / call pipeline / testsuite) |
| `testsuite_overlays/` | MS-MPI conf overlay copied into extracted VASP `testsuite/`        |
| `patches/`            | Win32 timing patches (`getrusage` → `GetProcessTimes`)             |
| `vasp_cmake/`         | Official VASP CMake port (**git submodule**)                       |


Research notes and evidence from the original workspace are intentionally
excluded. See [docs/DESIGN.md](docs/DESIGN.md) for a short design pointer.

---



## 2. Quick start: Clone → deps → build

All build steps below run in an **MSYS2 UCRT64** shell unless noted.
Install [MSYS2](https://www.msys2.org/) first if needed (Scoop is fine:
`scoop install msys2`). No Visual Studio and no Intel oneAPI are required.

### 2.1 Clone (with submodule)

```bash
git clone --recurse-submodules <this-repo-url>
cd vasp-windows-msys2-build
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

The submodule lives at `vasp_cmake/` (upstream
[vasp-dev/cmake](https://github.com/vasp-dev/cmake), branch `6.6.x`).
`build_pipeline.sh` expects that path by default (`VASP_CMAKE_DIR`).

### 2.2 Install deps (`toolchain/`)

In **UCRT64**:

```bash
bash toolchain/install_deps_msys2.sh
```

That installs the pacman packages (gcc/gfortran, cmake, ninja, msmpi,
OpenBLAS, ScaLAPACK, FFTW, dlfcn, zlib, ntldd, …). `dlfcn` supplies
`dlfcn.h` / `libdl` so internal **fftlib** (`VASP_FFTLIB=ON`, used with
OpenMP + FFTW) can build on MinGW. HDF5 is **not** from pacman
(self-built later via `toolchain/scripts` to avoid `libaws*`). Separately,
install **host** Microsoft MPI so the pipeline can harvest `mpiexec.exe` /
`smpd.exe` / `msmpi.dll` into the portable package:

```powershell
scoop install msmpi
```

or the official runtime (`msmpisetup.exe`) from
[https://www.microsoft.com/download/details.aspx?id=100362](https://www.microsoft.com/download/details.aspx?id=100362).

Optional override: `MSMPI_BIN=/c/path/to/Microsoft MPI/Bin`.

### 2.3 Get the VASP tarball yourself

Download your licensed VASP 6.6.x source archive from the VASP portal and keep
it **outside** this repository, for example:

```text
/c/Users/you/Downloads/vasp.6.6.0.tar.gz
```

Do not commit tarballs, extracted `vasp.*/` trees, or `POTCAR` / `potpaw*`
files. They are gitignored on purpose.

### 2.4 Build via toolchain

Point `VASP_TARBALL` at your licensed archive (MSYS `/c/...` or Windows
`C:\...` / `C:/...` — both work; the pipeline normalizes before unpack):

```bash
# UCRT64 shell — MSYS path (recommended)
export VASP_TARBALL='/c/Users/you/Downloads/vasp.6.6.0.tgz'
bash toolchain/build_vasp.sh
```

```powershell
# PowerShell — set env, then open UCRT64 / run bash (path is normalized)
$env:VASP_TARBALL='C:\Users\you\Downloads\vasp.6.6.0.tgz'
```

Or pass the path as `$1`:

```bash
bash toolchain/build_vasp.sh /c/path/to/vasp.6.6.0.tgz
# same as: VASP_TARBALL=/c/path/to/vasp.6.6.0.tgz bash toolchain/build_vasp.sh
```

Optional convenience: copy `toolchain/local.env.example` → `toolchain/local.env`
(gitignored) and set `VASP_TARBALL` there; `env_ucrt64.sh` sources it when present.

`toolchain/build_vasp.sh` sources `toolchain/env_ucrt64.sh` (PATH /
`MINGW_PREFIX` / `MSMPI_BIN`) then execs root `build_pipeline.sh`.
You may still call the pipeline directly:

```bash
bash build_pipeline.sh /c/path/to/vasp.6.6.0.tgz
```

Stages: `preflight → unpack → setup → patch → configure → build → harvest → package`.

**Output (local, gitignored):** `vasp-6.6.0-msys2-portable.zip` (+ `.sha256`).

### Tunables


| Variable           | Default                      | Purpose                                                             |
| ------------------ | ---------------------------- | ------------------------------------------------------------------- |
| `VASP_TARBALL`     | `$1`                         | Path to the VASP source tarball (MSYS `/c/...` or Windows `C:\...`) |
| `TARGET_CPU`       | `x86-64`                     | CPU baseline (`-march=`); use `native` for local speed              |
| `NUM_CORES`        | *(unset)*                    | Override ninja `-j` (else RAM-capped `nproc`)                       |
| `BUILD_VARIANTS`   | `vasp_std vasp_gam vasp_ncl` | Exes to harvest/bundle                                              |
| `PKG_NAME`         | `vasp-6.6.0-msys2-portable`  | Artifact name                                                       |
| `MINGW_PREFIX`     | `/ucrt64`                    | Resolved with `pwd -P` (Scoop symlinks OK)                          |
| `ALLOW_NON_UCRT64` | *(unset)*                    | Set `1` to skip the UCRT64 hard gate                                |
| `MSMPI_BIN`        | *(auto)*                     | Directory containing host `mpiexec.exe`                             |


For a stage-by-stage walkthrough, see [STEP_BY_STEP.md](STEP_BY_STEP.md).

---



## 3. Portable ZIP usage

Unzip anywhere. Place `INCAR`, `POSCAR`, `POTCAR`, `KPOINTS` next to `run.bat`,
then double-click `run.bat` (4-rank MS-MPI by default):

```bat
.\bin\mpiexec.exe -n 4 .\bin\vasp_std.exe
```

The package is self-contained: no MSYS2 or MS-MPI install is required on the
target machine (DLLs + launcher are bundled).

### Layout

```text
vasp-6.6.0-msys2-portable/
├── bin/
│   ├── vasp_std.exe  vasp_gam.exe  vasp_ncl.exe
│   ├── mpiexec.exe  smpd.exe  msmpi.dll
│   ├── libgfortran-*.dll  libgcc_s_seh-*.dll  libwinpthread-*.dll
│   ├── libstdc++-*.dll  libquadmath-*.dll  libgomp-*.dll
│   ├── libopenblas*.dll  libscalapack*.dll
│   └── libfftw3-*.dll  libhdf5*.dll  (+ HDF5 transitive deps)
└── run.bat
```

`run.bat` sets `OMP_NUM_THREADS=1` and `OPENBLAS_NUM_THREADS=1` so OpenBLAS
does not oversubscribe cores under MPI.

---



## 3.1 Official VASP testsuite (optional)

This repository does **not** ship the licensed `testsuite/` tree. After you
unpack a VASP tarball (e.g. under `build_work/vasp.6.6.0/`), run the harness
against the portable `bin/` with the MSYS2/MS-MPI overlay:

```bash
# UCRT64 — defaults: build_work/vasp.*/testsuite + build_work/vasp-*-msys2-portable/bin
bash toolchain/run_testsuite.sh
```

Overrides:

```bash
export TESTSUITE_ROOT='/c/path/to/vasp.6.6.0/testsuite'
export VASP_PORTABLE_BIN='/c/path/to/vasp-6.6.0-msys2-portable/bin'
bash toolchain/run_testsuite.sh          # copies overlay + builds compare tool
bash toolchain/run_testsuite.sh --fast   # same EXE_* via overlay, runtest --fast
```

What the runner does:

1. Copies `testsuite_overlays/msys2_msmpi.conf` into `${TESTSUITE_ROOT}/`
2. Builds `compare_numbertable_new` (gfortran) into `${TESTSUITE_ROOT}/tools/`
3. Sets `OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`, and `PATH` for the
   portable `bin/`
4. Runs `./runtest msys2_msmpi.conf` (MS-MPI `mpiexec` + `vasp_{std,gam,ncl}.exe`)

---



## 4. What we patch (and why)

Only two **timing/reporting** C files get a Win32 branch
(`src/lib/dclock_.c`, `src/lib/timing_.c`). MinGW-w64 does not provide
`getrusage()`; the patches use `GetProcessTimes()` instead.

**This affects OUTCAR timing/resource statistics only — not the physics.**
Patches live in `patches/` and are applied idempotently.

Everything else uses official CMake options (`VASP_OPENMP=ON`, `VASP_FFTLIB=ON`
with FFTW, `VASP_SHMEM=OFF`, `VASP_SYSV=OFF`, `VASP_TARGET_CPU`,
`BLA_VENDOR=OpenBLAS`, explicit MPI Fortran hints). On MinGW, fftlib needs
pacman `dlfcn` plus a tiny CMake inject (`shim/cmake_fftlib_win32_inject.cmake`)
that defines missing `RTLD_NOLOAD` — no System-V shared memory.

---



## 5. Troubleshooting


| Symptom                                                 | Fix                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `find_package(MPI)` fails                               | Install `mingw-w64-ucrt-x86_64-msmpi`; pipeline passes `-DMPI_Fortran_*`                                                                                                                                                                                                                           |
| `MSYSTEM=... must run in UCRT64`                        | Open **MSYS2 UCRT64**, or set `ALLOW_NON_UCRT64=1` only if you know why                                                                                                                                                                                                                            |
| `setup.sh` / CMakeLists missing                         | Init the submodule: `git submodule update --init --recursive`                                                                                                                                                                                                                                      |
| Symlink / CMakeLists not found                          | Pipeline materializes symlink targets as real files for Windows CMake                                                                                                                                                                                                                              |
| `cc1plus.exe: out of memory`                            | Lower parallelism: `NUM_CORES=2`                                                                                                                                                                                                                                                                   |
| `ntldd` shows `api-ms-*.dll` / `ext-ms-*.dll` not found | Harmless OS API-set stubs; packaging ignores them                                                                                                                                                                                                                                                  |
| Real MinGW DLL `not found`                              | Check Scoop-resolved `MINGW_PREFIX`; re-run harvest or copy missing DLL into `bin/`                                                                                                                                                                                                                |
| OpenBLAS crash under MPI                                | Keep `OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1` in `run.bat`                                                                                                                                                                                                                                   |
| Missing `mpiexec.exe` in package                        | Install host MS-MPI (`scoop install msmpi` or official setup); set `MSMPI_BIN` if needed                                                                                                                                                                                                           |
| `mpiexec -n 2` crashes (MSYS2/MS-MPI); `-n 1` OK        | **Fixed in current builds** via linker `--wrap` shim -- see [docs/MSMPI_INPLACE_SHIM.md](docs/MSMPI_INPLACE_SHIM.md) and [docs/MSYS2_MSMPI_MULTIRANK.md](docs/MSYS2_MSMPI_MULTIRANK.md). Rebuild with current `build_pipeline.sh`. Older ZIPs without the shim: use `-n 1` or an Intel MPI package |


---



## License reminder

VASP is proprietary. This repo only contains build glue (scripts, patches, and
a pointer to the public CMake port). You are responsible for complying with
your VASP license when obtaining source and running calculations.
