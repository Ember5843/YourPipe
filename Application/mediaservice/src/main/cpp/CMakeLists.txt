# CMakeLists.txt for Native Module in YourPipe Mediaservice
cmake_minimum_required(VERSION 3.16)
project(yourpipe_media)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# Fix OHOS_ARCH if not defined
if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH "arm64-v8a")
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(player SHARED
    napi_init.cpp
)

# libcurl from thirdparty (HarmonyOS cross-compiled, versioned as libcurl.so.4)
set(CURL_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../curl/${OHOS_ARCH})
if(EXISTS ${CURL_ROOT}/lib/libcurl.so.4.8.0)
    add_library(curl SHARED IMPORTED)
    set_target_properties(curl PROPERTIES
        IMPORTED_LOCATION ${CURL_ROOT}/lib/libcurl.so.4.8.0
        IMPORTED_SONAME   libcurl.so.4
    )
    target_include_directories(player PRIVATE ${CURL_ROOT}/include)
    target_sources(player PRIVATE
        stream/dash_session.cpp
        stream/http_client.cpp
        stream/range_proxy.cpp
        stream/local_dash_server.cpp
        stream/segment_cache.cpp
        stream/sidx_parser.cpp
    )
    target_compile_definitions(player PRIVATE HAS_CURL=1)
    set(CURL_FOUND TRUE)
else()
    message(STATUS "libcurl not found for ${OHOS_ARCH}, building ArkTS-only stub")
    set(CURL_FOUND FALSE)
endif()

find_library(hilog-lib hilog_ndk.z REQUIRED)
find_library(napi-lib ace_napi.z REQUIRED)
find_library(rawfile-lib rawfile.z REQUIRED)
find_library(uv-lib uv REQUIRED)
find_library(z-lib z REQUIRED)

set(LINK_LIBS
    libace_napi.z.so
    libhilog_ndk.z.so
    libc++.a
    ${hilog-lib}
    ${rawfile-lib}
    ${napi-lib}
    ${uv-lib}
    ${z-lib}
)
if(CURL_FOUND)
    list(APPEND LINK_LIBS curl)
endif()
target_link_libraries(player PUBLIC ${LINK_LIBS})
