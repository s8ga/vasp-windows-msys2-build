/* msmpi_inplace_wrap.c
 *
 * Linker --wrap shim for MSYS2 UCRT64 gfortran + MS-MPI.
 *
 * Problem: gfortran does not honor MSVC-style DLLIMPORT on the Fortran
 * COMMON blocks that define MPI_IN_PLACE / MPI_BOTTOM. Fortran therefore
 * passes &mpipriv1_.mpi_in_place (a fake local address) instead of the C
 * sentinel MPI_IN_PLACE ((void*)(MPI_Aint)-1). Collectives that rely on the
 * real sentinel then return wrong answers or corrupt memory under multi-rank.
 *
 * Fix: --wrap selected Fortran mpi_*_ entry points; if sendbuf equals the
 * fake COMMON address, replace with the real C sentinel, then call the C API.
 *
 * Verified approach: %TEMP%/mpi-inplace-wrap-test (Allreduce probe, 2026-07-21).
 * Optional debug: set MSMPI_WRAP_DEBUG=1
 *
 * Build (see also docs/MSYS2_MSMPI_MULTIRANK.md):
 *   gcc -c shim/msmpi_inplace_wrap.c -I"${MINGW_PREFIX}/include" -o msmpi_inplace_wrap.o
 *   link with: msmpi_inplace_wrap.o and -Wl,--wrap=mpi_<sym>_ for each wrapped symbol
 */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
  int mpi_bottom;
  int mpi_in_place;
} mpipriv1_t;

/* Same BSS COMMON gfortran emits for /MPIPRIV1/ (not the DLLIMPORT copy). */
extern mpipriv1_t mpipriv1_;

static void wrap_debug(const char *name, void *s, int remapped)
{
  if (!getenv("MSMPI_WRAP_DEBUG"))
    return;
  if (remapped)
    fprintf(stderr, "[wrap] %s: %p -> MPI_IN_PLACE/BOTTOM\n", name, s);
  fflush(stderr);
}

/* Map fake Fortran COMMON addresses to C MPI sentinels. */
static void *fix_buf(void *s, const char *name)
{
  void *fake_in_place = (void *)&mpipriv1_.mpi_in_place;
  void *fake_bottom = (void *)&mpipriv1_.mpi_bottom;

  if (s == fake_in_place) {
    wrap_debug(name, s, 1);
    return MPI_IN_PLACE;
  }
  if (s == fake_bottom) {
    wrap_debug(name, s, 1);
    return MPI_BOTTOM;
  }
  return s;
}

/* ---- collectives that accept MPI_IN_PLACE (sendbuf) ---- */

void __wrap_mpi_allreduce_(
    void *sendbuf, void *recvbuf,
    MPI_Fint *count, MPI_Fint *datatype,
    MPI_Fint *op, MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_allreduce_");
  *ierr = (MPI_Fint)MPI_Allreduce(
      s, recvbuf, (int)*count,
      MPI_Type_f2c(*datatype),
      MPI_Op_f2c(*op),
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_reduce_(
    void *sendbuf, void *recvbuf,
    MPI_Fint *count, MPI_Fint *datatype,
    MPI_Fint *op, MPI_Fint *root, MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_reduce_");
  *ierr = (MPI_Fint)MPI_Reduce(
      s, recvbuf, (int)*count,
      MPI_Type_f2c(*datatype),
      MPI_Op_f2c(*op),
      (int)*root,
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_allgather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_allgather_");
  *ierr = (MPI_Fint)MPI_Allgather(
      s, (int)*sendcount, MPI_Type_f2c(*sendtype),
      recvbuf, (int)*recvcount, MPI_Type_f2c(*recvtype),
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_allgatherv_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcounts, MPI_Fint *displs, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_allgatherv_");
  *ierr = (MPI_Fint)MPI_Allgatherv(
      s, (int)*sendcount, MPI_Type_f2c(*sendtype),
      recvbuf, (int *)recvcounts, (int *)displs, MPI_Type_f2c(*recvtype),
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_gather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *root, MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_gather_");
  *ierr = (MPI_Fint)MPI_Gather(
      s, (int)*sendcount, MPI_Type_f2c(*sendtype),
      recvbuf, (int)*recvcount, MPI_Type_f2c(*recvtype),
      (int)*root,
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_alltoall_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_alltoall_");
  *ierr = (MPI_Fint)MPI_Alltoall(
      s, (int)*sendcount, MPI_Type_f2c(*sendtype),
      recvbuf, (int)*recvcount, MPI_Type_f2c(*recvtype),
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_alltoallv_(
    void *sendbuf, MPI_Fint *sendcounts, MPI_Fint *sdispls, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcounts, MPI_Fint *rdispls, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_alltoallv_");
  *ierr = (MPI_Fint)MPI_Alltoallv(
      s, (int *)sendcounts, (int *)sdispls, MPI_Type_f2c(*sendtype),
      recvbuf, (int *)recvcounts, (int *)rdispls, MPI_Type_f2c(*recvtype),
      MPI_Comm_f2c(*comm));
}

void __wrap_mpi_iallgather_(
    void *sendbuf, MPI_Fint *sendcount, MPI_Fint *sendtype,
    void *recvbuf, MPI_Fint *recvcount, MPI_Fint *recvtype,
    MPI_Fint *comm, MPI_Fint *request, MPI_Fint *ierr)
{
  void *s = fix_buf(sendbuf, "mpi_iallgather_");
  MPI_Request req;
  *ierr = (MPI_Fint)MPI_Iallgather(
      s, (int)*sendcount, MPI_Type_f2c(*sendtype),
      recvbuf, (int)*recvcount, MPI_Type_f2c(*recvtype),
      MPI_Comm_f2c(*comm), &req);
  if (*ierr == (MPI_Fint)MPI_SUCCESS)
    *request = (MPI_Fint)MPI_Request_c2f(req);
}

/* RMA origin may use MPI_BOTTOM */
void __wrap_mpi_get_(
    void *origin_addr, MPI_Fint *origin_count, MPI_Fint *origin_datatype,
    MPI_Fint *target_rank, MPI_Aint *target_disp, MPI_Fint *target_count,
    MPI_Fint *target_datatype, MPI_Fint *win, MPI_Fint *ierr)
{
  void *o = fix_buf(origin_addr, "mpi_get_");
  *ierr = (MPI_Fint)MPI_Get(
      o, (int)*origin_count, MPI_Type_f2c(*origin_datatype),
      (int)*target_rank, (MPI_Aint)*target_disp, (int)*target_count,
      MPI_Type_f2c(*target_datatype),
      MPI_Win_f2c(*win));
}
