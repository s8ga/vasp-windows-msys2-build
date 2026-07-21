# CMAKE_PROJECT_TOP_LEVEL_INCLUDES helper — MinGW/Windows tweaks for VASP fftlib.
#
# dlfcn-win32 provides dlopen but not RTLD_NOLOAD (glibc extension). Define a
# high unused bit so it does not collide with RTLD_LOCAL=(1<<2). The win32
# wrapper ignores unknown mode bits, so "NOLOAD" checks become ordinary loads,
# which is acceptable for fftlib's FFTW dynamic loader on portable packages.
#
# Also ensure libdl is linked into VASP executables when fftlib objects are present.
# Optional: VASP_FFTW_PLANNER_SAFE_OBJ — object that calls
# fftw_make_planner_thread_safe() at startup.
#
# FFTW backend (MinGW): remap FFTW::FFTW_OMP from libfftw3_omp to libfftw3_threads.
# Upstream links the OpenMP FFTW backend when VASP_OPENMP=ON; that pulls a second
# libgomp path into plan creation. On UCRT64, bulk_BN_PBE0 at mpiexec -n4
# (OMP_NUM_THREADS=1) SIGSEGVs in libwinpthread under fftbas_plan_. The pthread
# FFTW backend keeps multi-threaded FFTW without nesting through libgomp.
# This is NOT "force serial FFTW".

function(_vasp_fftw_remap_omp_to_threads)
  if(NOT TARGET FFTW::FFTW_OMP)
    return()
  endif()

  set(_fftw_hints)
  if(DEFINED FFTW_ROOT AND NOT FFTW_ROOT STREQUAL "")
    list(APPEND _fftw_hints "${FFTW_ROOT}")
  endif()
  if(DEFINED ENV{FFTW_ROOT} AND NOT "$ENV{FFTW_ROOT}" STREQUAL "")
    list(APPEND _fftw_hints "$ENV{FFTW_ROOT}")
  endif()
  if(DEFINED MINGW_PREFIX AND NOT MINGW_PREFIX STREQUAL "")
    list(APPEND _fftw_hints "${MINGW_PREFIX}")
  endif()

  # Avoid a sticky NOTFOUND from an earlier configure.
  unset(VASP_FFTW_THREADS_LIB CACHE)
  find_library(VASP_FFTW_THREADS_LIB
    NAMES fftw3_threads libfftw3_threads
    HINTS ${_fftw_hints}
    PATH_SUFFIXES lib
    NO_CACHE)

  if(NOT VASP_FFTW_THREADS_LIB)
    message(WARNING "fftlib win32: libfftw3_threads not found; keeping libfftw3_omp")
    return()
  endif()

  # Replace imported-target link line (what VASP_EXTERNAL_LIBS uses).
  set_property(TARGET FFTW::FFTW_OMP PROPERTY INTERFACE_LINK_LIBRARIES
    "${VASP_FFTW_THREADS_LIB};FFTW::FFTW_SERIAL")

  # Also force the cache var FindFFTW published (belt-and-suspenders).
  set(FFTW_OMP_LIBRARIES "${VASP_FFTW_THREADS_LIB}" CACHE FILEPATH
    "FFTW OMP component remapped to pthread backend (MinGW)" FORCE)

  message(STATUS "fftlib win32: remapped FFTW::FFTW_OMP -> ${VASP_FFTW_THREADS_LIB} (pthread backend; not serial)")
endfunction()

function(_vasp_apply_fftlib_win32)
  if(TARGET fftlib_objects)
    # Avoid RTLD_NOLOAD=4 — that equals RTLD_LOCAL on dlfcn-win32.
    target_compile_definitions(fftlib_objects PRIVATE RTLD_NOLOAD=65536)
    message(STATUS "fftlib win32: defined RTLD_NOLOAD=65536 for MinGW dlfcn")
  endif()

  # Prefer FFTW pthread backend over OpenMP backend (keeps parallel FFTW).
  # Optional diagnostic: -DVASP_FFTW_FORCE_SERIAL=ON maps OMP -> SERIAL only.
  if(TARGET FFTW::FFTW_OMP)
    if(VASP_FFTW_FORCE_SERIAL)
      set_property(TARGET FFTW::FFTW_OMP PROPERTY INTERFACE_LINK_LIBRARIES
        "FFTW::FFTW_SERIAL")
      set(FFTW_OMP_LIBRARIES "${FFTW_SERIAL_LIBRARIES}" CACHE FILEPATH
        "FFTW OMP remapped to SERIAL (diagnostic)" FORCE)
      message(STATUS "fftlib win32: remapped FFTW::FFTW_OMP -> SERIAL (diagnostic; not threads)")
    else()
      _vasp_fftw_remap_omp_to_threads()
    endif()
  endif()

  foreach(_t vasp_std vasp_gam vasp_ncl)
    if(TARGET ${_t} AND TARGET fftlib_objects)
      target_link_libraries(${_t} PRIVATE dl)
      # Upstream cmake currently attaches fftlib_objects only to vasp_std;
      # keep that behavior. Linking dl on all variants is harmless.
      message(STATUS "fftlib win32: linked libdl to ${_t}")
    endif()
    if(TARGET ${_t} AND DEFINED VASP_FFTW_PLANNER_SAFE_OBJ AND NOT VASP_FFTW_PLANNER_SAFE_OBJ STREQUAL "")
      if(EXISTS "${VASP_FFTW_PLANNER_SAFE_OBJ}")
        target_link_libraries(${_t} PRIVATE "${VASP_FFTW_PLANNER_SAFE_OBJ}")
        # Cap FFTW worker threads (see shim/fftw_planner_thread_safe.c). Still
        # links libfftw3_threads — not the experimental serial stub.
        target_link_options(${_t} PRIVATE
          "-Wl,--wrap=fftw_plan_with_nthreads"
          "-Wl,--wrap=dfftw_plan_with_nthreads_"
          "-Wl,--wrap=dfftw_plan_with_nthreads__"
          "-Wl,--wrap=fftw_init_threads"
          "-Wl,--wrap=dfftw_init_threads_"
          "-Wl,--wrap=dfftw_init_threads__")
        message(STATUS "fftlib win32: linked FFTW planner-safe ctor + nthreads/init wraps to ${_t}")
      else()
        message(WARNING "VASP_FFTW_PLANNER_SAFE_OBJ missing: ${VASP_FFTW_PLANNER_SAFE_OBJ}")
      endif()
    endif()
  endforeach()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _vasp_apply_fftlib_win32)
