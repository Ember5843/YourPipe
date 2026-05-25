# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(video-player)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(youtubecore SHARED napi_init.cpp)
target_link_libraries(youtubecore PUBLIC libjsvm.so libace_napi.z.so libhilog_ndk.z.so)