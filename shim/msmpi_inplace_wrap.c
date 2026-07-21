/* msmpi_inplace_wrap.c
 *
 * Linker --wrap shim for MSYS2 UCRT64 gfortran + MS-MPI.
 *
 * Problem: gfortran does not honor MSVC-style DLLIMPORT on the Fortran
 * COMMON blocks that define MPI_IN_PLACE / MPI_BOTTOM. Fortran therefore
 * passes &mpipriv1_.mpi_in_place from a *local* BSS COMMON instead of the
 * MS-MPI DLL's /MPIPRIV1/. Collectives that key off the DLL sentinel then
 * return wrong answers or corrupt memory under multi-rank.
 *
 * Fix: --wrap selected Fortran mpi_*_ entry points. If sendbuf equals the
 * local fake COMMON address, rewrite it to the DLL COMMON address, then
 * call the original MS-MPI Fortran stub (__real_mpi_*_). That preserves
 * Fortran datatype/op/comm handles (avoids C MPI_* + MPI_Type_f2c, which
 * can yield MPI_DATATYPE_NULL for some MS-MPI Fortran handle encodings).
 *
 * Verified: local vs DLL mpipriv1_ addresses differ; C MPI_IN_PLACE is
 * (void*)-1. Optional debug: MSMPI_WRAP_DEBUG=1|2 (0/unset=off; mere
 * presence of the variable must not enable tracing).
 *
 * Build (see also docs/MSMPI_INPLACE_SHIM.md):
 *   gcc -c shim/msmpi_inplace_wrap.c -I"${MINGW_PREFIX}/include" -o msmpi_inplace_wrap.o
 *   link with: msmpi_inplace_wrap.o and -Wl,--wrap=mpi_<sym>_ for each wrapped symbol
 */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

typedef struct {
  int mpi_bottom;
  int mpi_in_place;
} mpipriv1_t;

enum { MSMPI_FORTRAN_STATUS_SIZE = 5 };

typedef struct {
  MPI_Fint mpi_statuses_ignore[MSMPI_FORTRAN_STATUS_SIZE];
  MPI_Fint mpi_errcodes_ignore[1];
} mpipriv2_t;

/* Local BSS COMMON that gfortran emits for /MPIPRIV1/ (fake sentinel). */
extern mpipriv1_t mpipriv1_;

/* Import thunk for MS-MPI DLL's /MPIPRIV1/ (real sentinel location). */
extern mpipriv1_t *__imp_mpipriv1_;

/* Local and DLL /MPIPRIV2/ COMMONs. The local MPI_STATUSES_IGNORE address is
 * not recognized by MS-MPI's Fortran stub and must be mapped to the DLL
 * COMMON before mpi_waitall_ sees it. */
extern mpipriv2_t mpipriv2_;
extern mpipriv2_t *__imp_mpipriv2_;

_Static_assert(sizeof(MPI_Fint) == sizeof(int),
               "MS-MPI Fortran INTEGER ABI must match C int");
_Static_assert(sizeof(mpipriv2_t) == 6 * sizeof(MPI_Fint),
               "MS-MPI /MPIPRIV2/ layout must be six Fortran INTEGERs");

/*
 * MSMPI_WRAP_DEBUG levels (unset / 0 / empty = off):
 *   1 — rank 0 only; NULL-dt / BAD_DATATYPE always; waitall remaps always;
 *       other IN_PLACE remaps rate-limited (first few). Avoids multi-rank
 *       stderr character interleaving that previously blew logs to ~3M lines
 *       and made testsuite SUMMARY false-FAIL despite correct E/F/S.
 *   2 — rank 0 only; every wrapped call (still line-atomic).
 *
 * Important: mere presence of the env var must NOT enable debug — older code
 * treated MSMPI_WRAP_DEBUG=0 as on.
 */
static int wrap_debug_level(void)
{
  static int once, level;
  if (!once) {
    const char *v;
    once = 1;
    level = 0;
    v = getenv("MSMPI_WRAP_DEBUG");
    if (v && v[0] != '\0' && v[0] != '0')
      level = (v[0] == '2') ? 2 : 1;
  }
  return level;
}

static int wrap_debug_enabled(void)
{
  return wrap_debug_level() > 0;
}

/* Prefer rank 0 so n-rank mpiexec does not interleave the same line N ways. */
static int wrap_debug_rank0(void)
{
  int inited = 0;
  int rank = 0;
  if (MPI_Initialized(&inited) != MPI_SUCCESS || !inited)
    return 1;
  if (MPI_Comm_rank(MPI_COMM_WORLD, &rank) != MPI_SUCCESS)
    return 1;
  return rank == 0;
}

#ifdef _WIN32
static CRITICAL_SECTION wrap_log_cs;
static volatile LONG wrap_log_cs_inited;

static void wrap_log_cs_ensure(void)
{
  if (InterlockedCompareExchange(&wrap_log_cs_inited, 1, 0) == 0) {
    InitializeCriticalSection(&wrap_log_cs);
    InterlockedExchange(&wrap_log_cs_inited, 2);
  } else {
    while (wrap_log_cs_inited != 2)
      Sleep(0);
  }
}
#endif

/* One WriteFile/fwrite of a complete line — avoids char-level interleaving
 * across MPI ranks that share the same redirected stderr pipe. */
static void wrap_log_line(const char *line)
{
  size_t n;
  if (!line)
    return;
  n = strlen(line);
#ifdef _WIN32
  {
    HANDLE h;
    DWORD written = 0;
    wrap_log_cs_ensure();
    EnterCriticalSection(&wrap_log_cs);
    h = GetStdHandle(STD_ERROR_HANDLE);
    if (h != INVALID_HANDLE_VALUE && h != NULL)
      WriteFile(h, line, (DWORD)n, &written, NULL);
    else
      fwrite(line, 1, n, stderr);
    LeaveCriticalSection(&wrap_log_cs);
  }
#else
  fputs(line, stderr);
  fflush(stderr);
#endif
}

static void wrap_debug_remap(const char *name, void *from, void *to)
{
  static unsigned inplace_budget = 8;
  char buf[256];
  int lvl = wrap_debug_level();
  if (lvl < 1 || !wrap_debug_rank0())
    return;
  /* Level 1: only a few routine IN_PLACE remaps (they dominate ACFDT/PBE0). */
  if (lvl == 1) {
    if (inplace_budget == 0)
      return;
    inplace_budget--;
  }
  snprintf(buf, sizeof(buf), "[wrap] %s: %p -> %p (DLL mpipriv1)\n", name, from,
           to);
  wrap_log_line(buf);
}

/* Log Fortran handles when MSMPI_WRAP_DEBUG is set; always note NULL dt. */
static void wrap_debug_handles(
    const char *name, int remapped,
    MPI_Fint *count, MPI_Fint *datatype, MPI_Fint *op, MPI_Fint *comm)
{
  char buf[320];
  MPI_Fint dt = datatype ? *datatype : (MPI_Fint)0xdeadbeef;
  int bad = (dt == 0) || (dt == (MPI_Fint)MPI_DATATYPE_NULL);
  int lvl = wrap_debug_level();
  static unsigned handle_budget = 8;
  if (lvl < 1 || !wrap_debug_rank0())
    return;
  /* Level 1: BAD always; remapped rate-limited; skip quiet non-remap. Level 2: all. */
  if (lvl < 2) {
    if (!bad && remapped == 0)
      return;
    if (!bad && remapped != 0) {
      if (handle_budget == 0)
        return;
      handle_budget--;
    }
  }
  snprintf(buf, sizeof(buf),
           "[wrap-h] %s remap=%d count=%d datatype=0x%x op=0x%x comm=0x%x%s\n",
           name, remapped, count ? (int)*count : -1, (unsigned)dt,
           op ? (unsigned)*op : 0u, comm ? (unsigned)*comm : 0u,
           bad ? " **BAD_DATATYPE**" : "");
  wrap_log_line(buf);
}

/* Map fake local COMMON addresses to MS-MPI DLL COMMON addresses.
 * Returns 1 if remapped, 0 otherwise. */
static int fix_buf(void **s_inout, const char *name)
{
  void *s = *s_inout;
  void *fake_in_place = (void *)&mpipriv1_.mpi_in_place;
  void *fake_bottom = (void *)&mpipriv1_.mpi_bottom;
  void *real_in_place = (void *)&__imp_mpipriv1_->mpi_in_place;
  void *real_bottom = (void *)&__imp_mpipriv1_->mpi_bottom;

  if (s == fake_in_place) {
    wrap_debug_remap(name, s, real_in_place);
    *s_inout = real_in_place;
    return 1;
  }
  if (s == fake_bottom) {
    wrap_debug_remap(name, s, real_bottom);
    *s_inout = real_bottom;
    return 1;
  }
  return 0;
}

/* Original MS-MPI Fortran stubs (provided by GNU ld --wrap). */
void __real_mpi_allreduce_(
    void *sendbuf, void *recvbuf,
    MPI_Fint *count, MPI_Fint *datatype,
    MPI_Fint *op, MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_reduce_(
    void *sendbuf, void *recvbuf,
    MPI_Fint *count, MPI_Fint *datatype,
    MPI_Fint *op, MPI_Fint *root, MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_allgather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_allgatherv_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcounts, MPI_Fint *displs, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_gather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *root, MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_alltoall_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_alltoallv_(
    void *sendbuf, MPI_Fint *sendcounts, MPI_Fint *sdispls, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcounts, MPI_Fint *rdispls, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr);
void __real_mpi_iallgather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *request, MPI_Fint *ierr);
void __real_mpi_waitall_(
    MPI_Fint *count, MPI_Fint *array_of_requests,
    MPI_Fint *array_of_statuses, MPI_Fint *ierr);
void __real_mpi_get_(
    void *origin_addr, MPI_Fint *origin_count, MPI_Fint *origin_datatype,
    MPI_Fint *target_rank, MPI_Aint *target_disp, MPI_Fint *target_count,
    MPI_Fint *target_datatype, MPI_Fint *win, MPI_Fint *ierr);

/* ---- collectives that accept MPI_IN_PLACE (sendbuf) ---- */

void __wrap_mpi_allreduce_(
    void *sendbuf, void *recvbuf,
    MPI_Fint *count, MPI_Fint *datatype,
    MPI_Fint *op, MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_allreduce_");
  MPI_Fint dt_local;
  MPI_Fint *dt_ptr = datatype;
  wrap_debug_handles("mpi_allreduce_", remapped, count, datatype, op, comm);
  /*
   * ACFDT (and similar) can call Fortran mpi_allreduce_ with a user MPI_Op
   * and MPI_DATATYPE_NULL on MS-MPI. MS-MPI rejects NULL even when the user
   * reduction ignores the type. Prefer a local substitute (do not write through
   * datatype — it may be a PARAMETER in r/o memory).
   * Override: MSMPI_NULL_DT_FALLBACK=double|byte|none (default double_complex).
   */
  if (datatype &&
      (*datatype == 0 || *datatype == (MPI_Fint)MPI_DATATYPE_NULL)) {
    const char *fb = getenv("MSMPI_NULL_DT_FALLBACK");
    if (!fb || fb[0] == '\0' || strcmp(fb, "double_complex") == 0)
      dt_local = (MPI_Fint)MPI_DOUBLE_COMPLEX;
    else if (strcmp(fb, "double") == 0)
      dt_local = (MPI_Fint)MPI_DOUBLE;
    else if (strcmp(fb, "byte") == 0)
      dt_local = (MPI_Fint)MPI_BYTE;
    else
      dt_local = *datatype; /* none / unknown: keep NULL, let MPI error */
    if (dt_local != *datatype) {
      if (wrap_debug_enabled() && wrap_debug_rank0()) {
        char buf[192];
        snprintf(buf, sizeof(buf),
                 "[wrap] mpi_allreduce_: NULL datatype -> 0x%x (count=%d op=0x%x)\n",
                 (unsigned)dt_local, count ? (int)*count : -1,
                 op ? (unsigned)*op : 0u);
        wrap_log_line(buf);
      }
      dt_ptr = &dt_local;
    }
  }
  __real_mpi_allreduce_(sendbuf, recvbuf, count, dt_ptr, op, comm, ierr);
}

void __wrap_mpi_reduce_(
    void *sendbuf, void *recvbuf,
    MPI_Fint *count, MPI_Fint *datatype,
    MPI_Fint *op, MPI_Fint *root, MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_reduce_");
  wrap_debug_handles("mpi_reduce_", remapped, count, datatype, op, comm);
  __real_mpi_reduce_(sendbuf, recvbuf, count, datatype, op, root, comm, ierr);
}

void __wrap_mpi_allgather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_allgather_");
  wrap_debug_handles("mpi_allgather_", remapped, sendcount, sendtype, NULL, comm);
  __real_mpi_allgather_(
      sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, ierr);
}

void __wrap_mpi_allgatherv_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcounts, MPI_Fint *displs, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_allgatherv_");
  wrap_debug_handles("mpi_allgatherv_", remapped, sendcount, sendtype, NULL, comm);
  __real_mpi_allgatherv_(
      sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, ierr);
}

void __wrap_mpi_gather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *root, MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_gather_");
  wrap_debug_handles("mpi_gather_", remapped, sendcount, sendtype, NULL, comm);
  __real_mpi_gather_(
      sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, ierr);
}

void __wrap_mpi_alltoall_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_alltoall_");
  wrap_debug_handles("mpi_alltoall_", remapped, sendcount, sendtype, NULL, comm);
  __real_mpi_alltoall_(
      sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, ierr);
}

void __wrap_mpi_alltoallv_(
    void *sendbuf, MPI_Fint *sendcounts, MPI_Fint *sdispls, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcounts, MPI_Fint *rdispls, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_alltoallv_");
  wrap_debug_handles("mpi_alltoallv_", remapped, sendcounts, sendtype, NULL, comm);
  __real_mpi_alltoallv_(
      sendbuf, sendcounts, sdispls, sendtype,
      recvbuf, recvcounts, rdispls, recvtype, comm, ierr);
}

void __wrap_mpi_iallgather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *request, MPI_Fint *ierr)
{
  int remapped = fix_buf(&sendbuf, "mpi_iallgather_");
  wrap_debug_handles("mpi_iallgather_", remapped, sendcount, sendtype, NULL, comm);
  __real_mpi_iallgather_(
      sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, request, ierr);
}

/* MS-MPI's Fortran mpi_waitall_ stub recognizes MPI_STATUSES_IGNORE only by
 * the address of the DLL's /MPIPRIV2/ COMMON. A gfortran-local COMMON address
 * otherwise reaches C MPI_Waitall as a writable status array. */
void __wrap_mpi_waitall_(
    MPI_Fint *count, MPI_Fint *array_of_requests,
    MPI_Fint *array_of_statuses, MPI_Fint *ierr)
{
  MPI_Fint *statuses = array_of_statuses;
  MPI_Fint *fake_statuses_ignore = &mpipriv2_.mpi_statuses_ignore[0];
  MPI_Fint *real_statuses_ignore = &__imp_mpipriv2_->mpi_statuses_ignore[0];

  if (statuses == fake_statuses_ignore) {
    /* Level 1: first few waitall remaps (high-value); level 2: all (rank 0). */
    if (wrap_debug_enabled() && wrap_debug_rank0()) {
      static unsigned waitall_budget = 16;
      int lvl = wrap_debug_level();
      if (lvl >= 2 || waitall_budget > 0) {
        char buf[256];
        if (lvl < 2)
          waitall_budget--;
        snprintf(buf, sizeof(buf),
                 "[wrap] mpi_waitall_: count=%d statuses %p -> %p (DLL mpipriv2)\n",
                 count ? (int)*count : -1, (void *)statuses,
                 (void *)real_statuses_ignore);
        wrap_log_line(buf);
      }
    }
    statuses = real_statuses_ignore;
  }

  __real_mpi_waitall_(count, array_of_requests, statuses, ierr);
}

/* RMA origin may use MPI_BOTTOM */
void __wrap_mpi_get_(
    void *origin_addr, MPI_Fint *origin_count, MPI_Fint *origin_datatype,
    MPI_Fint *target_rank, MPI_Aint *target_disp, MPI_Fint *target_count,
    MPI_Fint *target_datatype, MPI_Fint *win, MPI_Fint *ierr)
{
  int remapped = fix_buf(&origin_addr, "mpi_get_");
  wrap_debug_handles("mpi_get_", remapped, origin_count, origin_datatype, NULL, NULL);
  __real_mpi_get_(
      origin_addr, origin_count, origin_datatype,
      target_rank, target_disp, target_count, target_datatype, win, ierr);
}

/*
 * BLACS (inside MSYS2 libscalapack) default combine topology uses C
 * MPI_Allreduce + MPI_Op_create. On MS-MPI that path can abort with
 * MPI_DATATYPE_NULL (seen on multi-rank ACFDT; n=1 OK; Fortran mpi_*_
 * wraps never see count/op of the failing call).
 *
 * Netlib BLACS: if ctxt->TopsRepeat != 0, gsum2d forces tree topology
 * ('1') instead of MPI's reduction. SGET_TOPSREPEAT == 15 in Bdef.h.
 * Opt out: MSMPI_BLACS_TOPSREPEAT=0
 */
enum { BLACS_SGET_TOPSREPEAT = 15 };

void blacs_set_(MPI_Fint *ConTxt, MPI_Fint *what, MPI_Fint *val);
void blacs_get_(MPI_Fint *ConTxt, MPI_Fint *what, MPI_Fint *val);

void __real_blacs_gridinit_(
    MPI_Fint *ConTxt, char *order, MPI_Fint *nprow, MPI_Fint *npcol);
void __real_blacs_gridmap_(
    MPI_Fint *ConTxt, MPI_Fint *usermap, MPI_Fint *ldup,
    MPI_Fint *nprow0, MPI_Fint *npcol0);

static void blacs_force_tops_repeat(MPI_Fint *ConTxt)
{
  const char *env = getenv("MSMPI_BLACS_TOPSREPEAT");
  MPI_Fint what = BLACS_SGET_TOPSREPEAT;
  MPI_Fint val = 1;
  MPI_Fint got = -999;
  FILE *fp;
  if (env && (env[0] == '0') && env[1] == '\0')
    return;
  blacs_set_(ConTxt, &what, &val);
  blacs_get_(ConTxt, &what, &got);
  /* Always record to a file (stderr races under multi-rank mpiexec). */
  fp = fopen("msmpi_blacs_tops_repeat.log", "a");
  if (fp) {
    fprintf(fp, "ctxt=%d set=1 get=%d\n", (int)*ConTxt, (int)got);
    fclose(fp);
  }
  if (wrap_debug_enabled() && wrap_debug_rank0()) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "[wrap] blacs TopsRepeat set=1 get=%d ctxt=%d\n", (int)got,
             (int)*ConTxt);
    wrap_log_line(buf);
  }
}

void __wrap_blacs_gridinit_(
    MPI_Fint *ConTxt, char *order, MPI_Fint *nprow, MPI_Fint *npcol)
{
  __real_blacs_gridinit_(ConTxt, order, nprow, npcol);
  blacs_force_tops_repeat(ConTxt);
}

void __wrap_blacs_gridmap_(
    MPI_Fint *ConTxt, MPI_Fint *usermap, MPI_Fint *ldup,
    MPI_Fint *nprow0, MPI_Fint *npcol0)
{
  __real_blacs_gridmap_(ConTxt, usermap, ldup, nprow0, npcol0);
  blacs_force_tops_repeat(ConTxt);
}
