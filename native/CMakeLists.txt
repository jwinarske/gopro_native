# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joel Winarske
cmake_minimum_required(VERSION 3.22)
project(gopro_nc CXX C)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0)

# ── dart_api_dl — compile as plain C ────────────────────────────────────────
# Building this with g++ introduces C++ linkage on the extern "C" block and
# trips stricter aliasing rules around the void* casts in DartApiEntry. It
# must be a C translation unit.
add_library(dart_api_dl OBJECT src/dart_api_dl.c)
target_include_directories(dart_api_dl PUBLIC include)

# ── BLE protocol core — pure logic, no libusb, no BlueZ, no Dart ────────────
add_library(gopro_ble STATIC src/ble_protocol.cpp src/command_queue.cpp src/ble_link.cpp
                            src/query_parser.cpp
    src/ble_session.cpp src/ble_session.cpp)
target_include_directories(gopro_ble PUBLIC include)
target_compile_options(gopro_ble PRIVATE -Wall -Wextra -Wpedantic)

enable_testing()
add_executable(ble_protocol_test test/ble_protocol_test.cpp)
target_link_libraries(ble_protocol_test PRIVATE gopro_ble)
target_compile_options(ble_protocol_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME ble_protocol COMMAND ble_protocol_test)

add_executable(command_queue_test test/command_queue_test.cpp)
target_link_libraries(command_queue_test PRIVATE gopro_ble)
target_compile_options(command_queue_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME command_queue COMMAND command_queue_test)

add_executable(ble_link_test test/ble_link_test.cpp)
target_link_libraries(ble_link_test PRIVATE gopro_ble)
target_compile_options(ble_link_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME ble_link COMMAND ble_link_test)

add_executable(query_parser_test test/query_parser_test.cpp)
target_link_libraries(query_parser_test PRIVATE gopro_ble)
target_compile_options(query_parser_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME query_parser COMMAND query_parser_test)

add_executable(ble_session_test test/ble_session_test.cpp)
target_link_libraries(ble_session_test PRIVATE gopro_ble)
target_compile_options(ble_session_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME ble_session COMMAND ble_session_test)

# ── Discovery core, standalone-testable without Dart ────────────────────────
add_library(gopro_usb STATIC src/gopro_usb.cpp)
target_include_directories(gopro_usb PUBLIC include)
target_link_libraries(gopro_usb PUBLIC PkgConfig::LIBUSB)
target_compile_options(gopro_usb PRIVATE -Wall -Wextra -Wpedantic)

# ── Shared library for Dart FFI ─────────────────────────────────────────────
add_library(gopro_nc SHARED
    src/gopro_bridge.cpp
    src/gopro_usb.cpp
    src/ble_protocol.cpp
    src/command_queue.cpp
    src/ble_link.cpp
    src/query_parser.cpp
    src/ble_session.cpp
    $<TARGET_OBJECTS:dart_api_dl>
)
target_include_directories(gopro_nc PUBLIC include)
target_link_libraries(gopro_nc PRIVATE PkgConfig::LIBUSB pthread)
target_compile_options(gopro_nc PRIVATE -Wall -Wextra -Wpedantic)

# Only the extern "C" bridge entry points are part of the ABI. Everything
# else -- libusb symbols, the C++ discovery internals -- stays hidden.
set_target_properties(gopro_nc PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
target_link_options(gopro_nc PRIVATE
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/gopro_nc.map")
set_property(TARGET gopro_nc APPEND PROPERTY
    LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/gopro_nc.map)

# Enumerate-only invariant. See cmake/check_no_claim.cmake -- claiming an
# interface detaches cdc_ncm and destroys the HTTP transport.
add_custom_target(check_no_claim ALL
  COMMAND ${CMAKE_COMMAND}
          -DSRC_DIR=${CMAKE_CURRENT_SOURCE_DIR}/src
          -P ${CMAKE_CURRENT_SOURCE_DIR}/../cmake/check_no_claim.cmake
  COMMENT "Verifying the enumerate-only invariant")
add_dependencies(gopro_nc check_no_claim)
