cmake_minimum_required(VERSION 3.17)
project(yourpipe_cipher)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(yourpipe_cipher MODULE cipher_jsvm_napi.cpp)
target_link_libraries(yourpipe_cipher ace_napi.z hilog_ndk.z jsvm)
