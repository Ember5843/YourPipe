cmake_minimum_required(VERSION 3.17)
project(yourpipe_cipher)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(yourpipe_cipher MODULE cipher_jsvm_napi.cpp)

# Device Security Kit: query Secure Shield mode (HMS_DSM_GetDeviceSecurityMode).
find_library(dsm-lib libdevice_security_mode.z.so)
if(dsm-lib)
  target_link_libraries(yourpipe_cipher ace_napi.z hilog_ndk.z jsvm ${dsm-lib})
else()
  message(WARNING "libdevice_security_mode.z.so not found; Secure Shield probe will return false")
  target_link_libraries(yourpipe_cipher ace_napi.z hilog_ndk.z jsvm)
  target_compile_definitions(yourpipe_cipher PRIVATE YOURPIPE_NO_DEVICE_SECURITY_MODE=1)
endif()
