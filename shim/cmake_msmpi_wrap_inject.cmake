# CMAKE_PROJECT_TOP_LEVEL_INCLUDES helper — apply MS-MPI MPI_IN_PLACE --wrap
# only to VASP executables (not CMake try_compile / compiler tests).
#
# Required cache vars (set by build_pipeline.sh before configure):
#   VASP_MSMPI_WRAP_OBJ   — absolute path to msmpi_inplace_wrap.o (Windows or MSYS)
#   VASP_MSMPI_WRAP_SYMS  — semicolon-separated Fortran symbols, e.g. mpi_allreduce_;mpi_reduce_

if(NOT DEFINED VASP_MSMPI_WRAP_OBJ OR VASP_MSMPI_WRAP_OBJ STREQUAL "")
  message(FATAL_ERROR "VASP_MSMPI_WRAP_OBJ is not set (MS-MPI IN_PLACE wrap object)")
endif()

if(NOT DEFINED VASP_MSMPI_WRAP_SYMS OR VASP_MSMPI_WRAP_SYMS STREQUAL "")
  message(FATAL_ERROR "VASP_MSMPI_WRAP_SYMS is not set")
endif()

function(_vasp_apply_msmpi_inplace_wrap)
  if(NOT EXISTS "${VASP_MSMPI_WRAP_OBJ}")
    message(FATAL_ERROR "MS-MPI wrap object missing: ${VASP_MSMPI_WRAP_OBJ}")
  endif()

  set(_wrap_opts)
  foreach(_sym IN LISTS VASP_MSMPI_WRAP_SYMS)
    if(NOT _sym STREQUAL "")
      # GNU ld: -Wl,--wrap=symbol
      list(APPEND _wrap_opts "LINKER:--wrap=${_sym}")
    endif()
  endforeach()

  set(_applied FALSE)
  foreach(_t vasp_std vasp_gam vasp_ncl)
    if(TARGET ${_t})
      target_link_options(${_t} PRIVATE ${_wrap_opts})
      target_link_libraries(${_t} PRIVATE "${VASP_MSMPI_WRAP_OBJ}")
      message(STATUS "MS-MPI IN_PLACE --wrap applied to ${_t}")
      set(_applied TRUE)
    endif()
  endforeach()

  if(NOT _applied)
    message(WARNING "MS-MPI wrap inject: no vasp_std/gam/ncl targets found yet")
  endif()
endfunction()

# Run after the root CMakeLists.txt has defined the VASP executable targets.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _vasp_apply_msmpi_inplace_wrap)
