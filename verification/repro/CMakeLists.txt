# Builds every reproduction program in this directory against one SDL source tree, given as
# -DSDL_SOURCE=<path>. SDL is built static so that f020 can reach SDL's internal hotplug entry
# points. Sanitizer flags come from CMAKE_C_FLAGS (run.sh sets them).
cmake_minimum_required(VERSION 3.16)
project(sdl_repro C)

set(SDL_SOURCE "" CACHE PATH "SDL source tree to build the reproductions against")
if(NOT EXISTS "${SDL_SOURCE}/CMakeLists.txt")
  message(FATAL_ERROR "SDL_SOURCE must point at an SDL source tree")
endif()

set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${SDL_SOURCE}" sdl EXCLUDE_FROM_ALL)

# f021 plays an audio backend, and the backend-facing API differs between the trees: the fix
# added SDL_FindAndRefPhysicalAudioDeviceByHandle for backends to call (see f021's comment).
file(READ "${SDL_SOURCE}/src/audio/SDL_sysaudio.h" sysaudio_h)
string(FIND "${sysaudio_h}" "SDL_FindAndRefPhysicalAudioDeviceByHandle" find_and_ref)

file(GLOB repro_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/f*.c")
foreach(src IN LISTS repro_sources)
  get_filename_component(name "${src}" NAME_WE)
  if(name STREQUAL "f027_strtol_radix")
    # Compiles SDL_string.c itself with the libc-less minimal config (see the file), so it does
    # not link SDL. The CBMC config header comes first and selects SDL_build_config_minimal.h.
    add_executable(${name} "${src}")
    target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../cbmc/include"
      "${SDL_SOURCE}/include" "${SDL_SOURCE}/src" "${CMAKE_CURRENT_SOURCE_DIR}")
    continue()
  endif()
  add_executable(${name} "${src}")
  target_link_libraries(${name} PRIVATE SDL3::SDL3-static)
  if(NOT find_and_ref EQUAL -1)
    target_compile_definitions(${name} PRIVATE REPRO_HAVE_FIND_AND_REF)
  endif()
endforeach()
