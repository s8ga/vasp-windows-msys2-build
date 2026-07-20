# VASP 6.6.x — Windows Portable Build (MSYS2 / UCRT64)

One-command pipeline that turns a **licensed VASP source tarball** (obtained by
you) into a **portable ZIP** containing `vasp_std` / `vasp_gam` / `vasp_ncl`,
runtime DLLs, the MS-MPI launcher, and a simple `run.bat`.

Toolchain (open source + Microsoft MPI):

```text
gfortran (UCRT64) + MS-MPI + OpenBLAS + ScaLAPACK(msmpi) + FFTW + HDF5
```

**This repository does not ship VASP source code, POTCAR files, or prebuilt
binaries.** You must provide your own licensed VASP tarball outside this repo.

---

## 1. What this is

| Item | Role |
|---|---|
| `build_pipeline.sh` | One-command driver (preflight → zip) |
| `patches/` | Win32 timing patches (`getrusage` → `GetProcessTimes`) |
| `vasp_cmake/` | Official VASP CMake port (**git submodule**) |

Research notes and evidence from the original workspace are intentionally
excluded. See [docs/DESIGN.md](docs/DESIGN.md) for a short design pointer.

---

## 2. Prerequisites (build host)

### 2.1 MSYS2 UCRT64

Install [MSYS2](https://www.msys2.org/) (Scoop is fine: `scoop install msys2`).
Open the **UCRT64** shell and install:

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-fortran \
  mingw-w64-ucrt-x86_64-binutils mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-msmpi \
  mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-scalapack \
  mingw-w64-ucrt-x86_64-fftw mingw-w64-ucrt-x86_64-hdf5 \
  mingw-w64-ucrt-x86_64-ntldd git tar zip
```

### 2.2 Host Microsoft MPI (launcher)

Needed so the pipeline can harvest `mpiexec.exe` / `smpd.exe` / `msmpi.dll`
into the portable package. Either:

```powershell
scoop install msmpi
```

or install the official runtime (`msmpisetup.exe`) from
<https://www.microsoft.com/download/details.aspx?id=100362>.

Optional override: `MSMPI_BIN=/c/path/to/Microsoft MPI/Bin`.

No Visual Studio and no Intel oneAPI are required.

---

## 3. Clone this repo (with submodule)

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

---

## 4. Get the VASP tarball yourself

Download your licensed VASP 6.6.x source archive from the VASP portal and keep
it **outside** this repository, for example:

```text
/c/Users/you/Downloads/vasp.6.6.0.tar.gz
```

Do not commit tarballs, extracted `vasp.*/` trees, or `POTCAR` / `potpaw*`
files. They are gitignored on purpose.

---

## 5. Build (one command)

In the **MSYS2 UCRT64** shell, from this folder:

```bash
VASP_TARBALL=/c/path/to/vasp.6.6.0.tar.gz bash build_pipeline.sh
```

Or:

```bash
bash build_pipeline.sh /c/path/to/vasp.6.6.0.tar.gz
```

Stages: `preflight → unpack → setup → patch → configure → build → harvest → package`.

**Output (local, gitignored):** `vasp-6.6.0-msys2-portable.zip` (+ `.sha256`).

### Tunables

| Variable | Default | Purpose |
|---|---|---|
| `VASP_TARBALL` | `$1` | Path to the VASP source tarball |
| `TARGET_CPU` | `x86-64` | CPU baseline (`-march=`); use `native` for local speed |
| `NUM_CORES` | *(unset)* | Override ninja `-j` (else RAM-capped `nproc`) |
| `BUILD_VARIANTS` | `vasp_std vasp_gam vasp_ncl` | Exes to harvest/bundle |
| `PKG_NAME` | `vasp-6.6.0-msys2-portable` | Artifact name |
| `MINGW_PREFIX` | `/ucrt64` | Resolved with `pwd -P` (Scoop symlinks OK) |
| `ALLOW_NON_UCRT64` | *(unset)* | Set `1` to skip the UCRT64 hard gate |
| `MSMPI_BIN` | *(auto)* | Directory containing host `mpiexec.exe` |

For a stage-by-stage walkthrough, see [STEP_BY_STEP.md](STEP_BY_STEP.md).

---

## 6. Portable ZIP usage

Unzip anywhere. Place `INCAR`, `POSCAR`, `POTCAR`, `KPOINTS` next to `run.bat`,
then double-click **`run.bat`** (4-rank MS-MPI by default):

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

## 7. What we patch (and why)

Only two **timing/reporting** C files get a Win32 branch
(`src/lib/dclock_.c`, `src/lib/timing_.c`). MinGW-w64 does not provide
`getrusage()`; the patches use `GetProcessTimes()` instead.

**This affects OUTCAR timing/resource statistics only — not the physics.**
Patches live in `patches/` and are applied idempotently.

Everything else uses official CMake options (`VASP_SHMEM=OFF`, `VASP_SYSV=OFF`,
`VASP_TARGET_CPU`, `BLA_VENDOR=OpenBLAS`, explicit MPI Fortran hints).

---

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `find_package(MPI)` fails | Install `mingw-w64-ucrt-x86_64-msmpi`; pipeline passes `-DMPI_Fortran_*` |
| `MSYSTEM=... must run in UCRT64` | Open **MSYS2 UCRT64**, or set `ALLOW_NON_UCRT64=1` only if you know why |
| `setup.sh` / CMakeLists missing | Init the submodule: `git submodule update --init --recursive` |
| Symlink / CMakeLists not found | Pipeline materializes symlink targets as real files for Windows CMake |
| `cc1plus.exe: out of memory` | Lower parallelism: `NUM_CORES=2` |
| `ntldd` shows `api-ms-*.dll` / `ext-ms-*.dll` not found | Harmless OS API-set stubs; packaging ignores them |
| Real MinGW DLL `not found` | Check Scoop-resolved `MINGW_PREFIX`; re-run harvest or copy missing DLL into `bin/` |
| OpenBLAS crash under MPI | Keep `OMP_NUM_THREADS=1` / `OPENBLAS_NUM_THREADS=1` in `run.bat` |
| Missing `mpiexec.exe` in package | Install host MS-MPI (`scoop install msmpi` or official setup); set `MSMPI_BIN` if needed |

---

## License reminder

VASP is proprietary. This repo only contains build glue (scripts, patches, and
a pointer to the public CMake port). You are responsible for complying with
your VASP license when obtaining source and running calculations.
