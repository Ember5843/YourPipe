cmake_minimum_required(VERSION 3.17)
project(asr_engine)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(asr_engine MODULE asr_decode_napi.cpp)

# 系统 NDK：解封装/音频解码（同步模式）。两个 ABI 均为系统能力，无 vendored 依赖。
target_link_libraries(asr_engine
  ace_napi.z
  hilog_ndk.z
  native_media_avdemuxer
  native_media_avsource
  native_media_acodec
  native_media_codecbase
  native_media_core)
