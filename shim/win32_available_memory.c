/*
 * Win32 available-memory helper for VASP AUTOSET_AVAILABLE_MEMORY.
 *
 * Native Windows PE has no Linux /proc/meminfo. This returns currently
 * available physical RAM in kibibytes (kB), matching VASP's MEMSIZE units.
 *
 * Build (UCRT64):
 *   gcc -c shim/win32_available_memory.c -o win32_available_memory.o
 *
 * Fortran (ISO_C_BINDING):
 *   INTEGER(C_INT64_T) FUNCTION vasp_win32_available_memory_kb() &
 *      BIND(C, NAME='vasp_win32_available_memory_kb')
 */

#ifdef _WIN32
#  include <windows.h>
#endif

#include <stdint.h>

int64_t vasp_win32_available_memory_kb(void)
{
#ifdef _WIN32
    MEMORYSTATUSEX st;

    st.dwLength = sizeof(st);
    if (!GlobalMemoryStatusEx(&st))
        return 0;

    /* ullAvailPhys is bytes; VASP MEMSIZE is kB (same as MemAvailable). */
    return (int64_t)(st.ullAvailPhys / 1024ULL);
#else
    return 0;
#endif
}
