# CMAKE_PROJECT_TOP_LEVEL_INCLUDES helper — link Win32 available-memory
# object into VASP executables only (not CMake try_compile).
#
# Required cache var (set by build_pipeline.sh before configure):
#   VASP_WIN32_MEM_OBJ — absolute path to win32_available_memory.o

if(NOT DEFINED VASP_WIN32_MEM_OBJ OR VASP_WIN32_MEM_OBJ STREQUAL "")
  message(FATAL_ERROR "VASP_WIN32_MEM_OBJ is not set (Win32 MAXMEM helper object)")
endif()

function(_vasp_apply_win32_available_memory)
  if(NOT EXISTS "${VASP_WIN32_MEM_OBJ}")
    message(FATAL_ERROR "Win32 MAXMEM object missing: ${VASP_WIN32_MEM_OBJ}")
  endif()

  set(_applied FALSE)
  foreach(_t vasp_std vasp_gam vasp_ncl)
    if(TARGET ${_t})
      target_link_libraries(${_t} PRIVATE "${VASP_WIN32_MEM_OBJ}")
      message(STATUS "Win32 available-memory helper linked to ${_t}")
      set(_applied TRUE)
    endif()
  endforeach()

  if(NOT _applied)
    message(WARNING "Win32 mem inject: no vasp_std/gam/ncl targets found yet")
  endif()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _vasp_apply_win32_available_memory)
