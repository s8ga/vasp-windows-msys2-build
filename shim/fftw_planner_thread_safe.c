/*
 * MinGW/UCRT64: FFTW planner hardening for MS-MPI multi-rank hybrids.
 *
 * Complements cmake_fftlib_win32_inject.cmake (libfftw3_omp -> libfftw3_threads).
 * Keeps the pthread FFTW backend linked. Raise VASP_FFTW_MAX_THREADS to enable
 * FFTW worker threads. Default max=1 skips fftw_init_threads (avoids winpthread
 * in the default hybrid path). Not the experimental serial stub.
 */
#include <fftw3.h>
#include <stdlib.h>

static int vasp_fftw_max_threads(void) {
  const char *e = getenv("VASP_FFTW_MAX_THREADS");
  if (e && e[0]) {
    int n = atoi(e);
    if (n < 1) {
      n = 1;
    }
    return n;
  }
  return 1;
}

static int vasp_fftw_clamp_threads(int nthreads) {
  int max_n = vasp_fftw_max_threads();
  if (nthreads < 1) {
    nthreads = 1;
  }
  if (nthreads > max_n) {
    nthreads = max_n;
  }
  return nthreads;
}

static int vasp_fftw_want_thread_pool(void) {
  return vasp_fftw_max_threads() > 1;
}

#if defined(__GNUC__)
__attribute__((constructor))
#endif
static void vasp_fftw_planner_thread_safe_ctor(void) {
  if (!vasp_fftw_want_thread_pool()) {
    return;
  }
  (void)fftw_init_threads();
  fftw_make_planner_thread_safe();
  fftw_plan_with_nthreads(vasp_fftw_max_threads());
}

void __real_fftw_plan_with_nthreads(int nthreads);
void __wrap_fftw_plan_with_nthreads(int nthreads) {
  if (!vasp_fftw_want_thread_pool()) {
    return;
  }
  __real_fftw_plan_with_nthreads(vasp_fftw_clamp_threads(nthreads));
}

void __real_dfftw_plan_with_nthreads_(int *nthreads);
void __wrap_dfftw_plan_with_nthreads_(int *nthreads) {
  if (!vasp_fftw_want_thread_pool()) {
    return;
  }
  int n = nthreads ? *nthreads : 1;
  n = vasp_fftw_clamp_threads(n);
  __real_dfftw_plan_with_nthreads_(&n);
}

void __real_dfftw_plan_with_nthreads__(int *nthreads);
void __wrap_dfftw_plan_with_nthreads__(int *nthreads) {
  if (!vasp_fftw_want_thread_pool()) {
    return;
  }
  int n = nthreads ? *nthreads : 1;
  n = vasp_fftw_clamp_threads(n);
  __real_dfftw_plan_with_nthreads__(&n);
}

int __real_fftw_init_threads(void);
int __wrap_fftw_init_threads(void) {
  if (!vasp_fftw_want_thread_pool()) {
    return 1;
  }
  return __real_fftw_init_threads();
}

void __real_dfftw_init_threads_(void);
void __wrap_dfftw_init_threads_(void) {
  if (!vasp_fftw_want_thread_pool()) {
    return;
  }
  __real_dfftw_init_threads_();
}

void __real_dfftw_init_threads__(void);
void __wrap_dfftw_init_threads__(void) {
  if (!vasp_fftw_want_thread_pool()) {
    return;
  }
  __real_dfftw_init_threads__();
}
