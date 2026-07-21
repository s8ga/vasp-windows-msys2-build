# Apply the Win32 native lock replacement only to VASP executables.
#
# VASP_GOMP_CRITICAL_WIN32_OBJ is built by build_pipeline.sh.  An empty value
# disables the shim (for diagnostics or when VASP_OPENMP=OFF).

function(_vasp_apply_gomp_critical_win32)
  if(NOT DEFINED VASP_GOMP_CRITICAL_WIN32_OBJ
     OR VASP_GOMP_CRITICAL_WIN32_OBJ STREQUAL "")
    message(STATUS "GOMP named-critical Win32 shim disabled")
    return()
  endif()

  if(NOT EXISTS "${VASP_GOMP_CRITICAL_WIN32_OBJ}")
    message(FATAL_ERROR
      "GOMP named-critical Win32 object missing: ${VASP_GOMP_CRITICAL_WIN32_OBJ}")
  endif()

  foreach(_t vasp_std vasp_gam vasp_ncl)
    if(TARGET ${_t})
      target_link_libraries(${_t} PRIVATE "${VASP_GOMP_CRITICAL_WIN32_OBJ}")
      target_link_options(${_t} PRIVATE
        "LINKER:--wrap=GOMP_critical_name_start"
        "LINKER:--wrap=GOMP_critical_name_end")
      message(STATUS
        "GOMP FFT planner critical -> Win32 SRWLOCK shim applied to ${_t}")
    endif()
  endforeach()
endfunction()

cmake_language(
  DEFER DIRECTORY "${CMAKE_SOURCE_DIR}"
  CALL _vasp_apply_gomp_critical_win32)
