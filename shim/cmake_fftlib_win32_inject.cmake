# CMAKE_PROJECT_TOP_LEVEL_INCLUDES helper — MinGW/Windows tweaks for VASP fftlib.
#
# dlfcn-win32 provides dlopen but not RTLD_NOLOAD (glibc extension). Define a
# high unused bit so it does not collide with RTLD_LOCAL=(1<<2). The win32
# wrapper ignores unknown mode bits, so "NOLOAD" checks become ordinary loads,
# which is acceptable for fftlib's FFTW dynamic loader on portable packages.
#
# Also ensure libdl is linked into VASP executables when fftlib objects are present.

function(_vasp_apply_fftlib_win32)
  if(TARGET fftlib_objects)
    # Avoid RTLD_NOLOAD=4 — that equals RTLD_LOCAL on dlfcn-win32.
    target_compile_definitions(fftlib_objects PRIVATE RTLD_NOLOAD=65536)
    message(STATUS "fftlib win32: defined RTLD_NOLOAD=65536 for MinGW dlfcn")
  endif()

  foreach(_t vasp_std vasp_gam vasp_ncl)
    if(TARGET ${_t} AND TARGET fftlib_objects)
      target_link_libraries(${_t} PRIVATE dl)
      # Upstream cmake currently attaches fftlib_objects only to vasp_std;
      # keep that behavior. Linking dl on all variants is harmless.
      message(STATUS "fftlib win32: linked libdl to ${_t}")
    endif()
  endforeach()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _vasp_apply_fftlib_win32)
