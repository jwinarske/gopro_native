# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joel Winarske
# Enforces the enumerate-only invariant documented in src/gopro_usb.h.
#
# Claiming an interface detaches the kernel's cdc_ncm/rndis_host driver, which
# tears down the very netdev the HTTP control API rides on. That failure is
# silent and confusing -- the camera "disappears" from the network the instant
# discovery runs -- so it is cheaper to make it a build error than to debug it.

set(FORBIDDEN
    libusb_claim_interface
    libusb_detach_kernel_driver
    libusb_set_auto_detach_kernel_driver
    libusb_release_interface
    libusb_set_configuration)

file(GLOB_RECURSE SOURCES "${SRC_DIR}/*.cpp" "${SRC_DIR}/*.h")

set(VIOLATIONS "")
foreach(file ${SOURCES})
  file(STRINGS "${file}" lines)
  set(lineno 0)
  foreach(line ${lines})
    math(EXPR lineno "${lineno} + 1")
    # Skip comments -- the header names these APIs to explain why they are banned.
    string(REGEX MATCH "^[ \t]*(//|\\*|/\\*)" is_comment "${line}")
    if(is_comment)
      continue()
    endif()
    foreach(sym ${FORBIDDEN})
      string(FIND "${line}" "${sym}" pos)
      if(NOT pos EQUAL -1)
        list(APPEND VIOLATIONS "${file}:${lineno}: ${sym}")
      endif()
    endforeach()
  endforeach()
endforeach()

if(VIOLATIONS)
  message("Enumerate-only invariant violated:")
  foreach(v ${VIOLATIONS})
    message("  ${v}")
  endforeach()
  message(FATAL_ERROR
      "Claiming the interface detaches cdc_ncm and destroys the HTTP transport. "
      "See the invariant note in src/gopro_usb.h.")
endif()
