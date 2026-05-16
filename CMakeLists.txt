cmake_minimum_required(VERSION 3.21)
project(rtc
  VERSION 0.1.0
  LANGUAGES C CXX)

option(RTC_BUNDLE_DEPS
  "Build libdatachannel and mbedtls from source as static archives, \
folding them into the Tcl extension with no runtime .so dependency on them."
  OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

add_compile_options(-Wall -Wextra)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)

find_package(Threads REQUIRED)

if(RTC_BUNDLE_DEPS)
  # Builds mbedtls + libdatachannel via ExternalProject_Add into
  # ${CMAKE_BINARY_DIR}/vendor; exposes Rtc::libdatachannel as an
  # imported target that folds the resulting static archives - plus
  # libstdc++ - into anything that links it.
  include(BundleDeps)
else()
  find_package(LibDataChannel REQUIRED)
  add_library(Rtc::libdatachannel INTERFACE IMPORTED)
  target_link_libraries(Rtc::libdatachannel INTERFACE LibDataChannel::LibDataChannel)
endif()

add_subdirectory(tcl)

enable_testing()
add_subdirectory(tests)
