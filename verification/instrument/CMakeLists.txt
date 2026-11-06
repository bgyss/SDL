# Builds an instrumented SDL (the tree in -DSDL_SOURCE, which build.sh has patched with
# <spec>.patch) and the trace programs. Static, so the programs can define the trace hooks
# that the patched SDL calls.
cmake_minimum_required(VERSION 3.16)
project(sdl_verif_trace C)

set(SDL_SOURCE "" CACHE PATH "patched SDL source tree")
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${SDL_SOURCE}" sdl EXCLUDE_FROM_ALL)
target_include_directories(SDL3-static PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

foreach(name trace_audio trace_events)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${name}.c")
    add_executable(${name} "${name}.c")
    target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(${name} PRIVATE SDL3::SDL3-static)
  endif()
endforeach()
