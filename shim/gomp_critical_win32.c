/*
 * MinGW/UCRT64: bypass libgomp/winpthreads for VASP's FFTW planner lock.
 *
 * GCC lowers the named OpenMP critical region
 *
 *   VASP_FFT_PLAN_CREATE_DESTROY
 *
 * to GOMP_critical_name_start/end calls with the address of the external
 * .gomp_critical_user_vasp_fft_plan_create_destroy slot.  On Windows, the
 * PBE0 force path has been observed to SIGSEGV inside libwinpthread while
 * entering that lock, before the first FFTW planner call executes.
 *
 * GNU ld --wrap redirects all named critical calls here.  Only the FFTW
 * planner lock uses a native Windows SRW lock; every other named critical
 * remains handled by libgomp.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

extern void *vasp_fft_plan_critical_slot
    __asm__(".gomp_critical_user_vasp_fft_plan_create_destroy");

void __real_GOMP_critical_name_start(void **slot);
void __real_GOMP_critical_name_end(void **slot);

static SRWLOCK vasp_fft_plan_lock = SRWLOCK_INIT;

static int is_vasp_fft_plan_lock(void **slot) {
  return slot == &vasp_fft_plan_critical_slot;
}

void __wrap_GOMP_critical_name_start(void **slot) {
  if (is_vasp_fft_plan_lock(slot)) {
    AcquireSRWLockExclusive(&vasp_fft_plan_lock);
    return;
  }
  __real_GOMP_critical_name_start(slot);
}

void __wrap_GOMP_critical_name_end(void **slot) {
  if (is_vasp_fft_plan_lock(slot)) {
    ReleaseSRWLockExclusive(&vasp_fft_plan_lock);
    return;
  }
  __real_GOMP_critical_name_end(slot);
}
