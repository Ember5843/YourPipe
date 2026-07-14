cmake_minimum_required(VERSION 3.17)
project(mdk_napi)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# x86_64: emulator UI/debug stub (no vendored libmpv/FFmpeg for this ABI yet)
# arm64-v8a: full product path
# ---------------------------------------------------------------------------
if(OHOS_ARCH STREQUAL "x86_64")
    message(STATUS "libmdk_napi: building x86_64 STUB (emulator UI only, no real playback)")

    # Keep target name for build-profile externalNativeOptions.targets
    add_library(mpv_ohcodec_shim SHARED
        mpv_ohcodec_shim.cpp
    )

    add_library(mdk_napi MODULE
        player_napi_stub.cpp
    )

    target_link_libraries(mdk_napi
        ace_napi.z
        ace_ndk.z
        hilog_ndk.z
    )

    add_dependencies(mdk_napi mpv_ohcodec_shim)
    add_custom_command(TARGET mdk_napi POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:mpv_ohcodec_shim>"
                "$<TARGET_FILE_DIR:mdk_napi>/$<TARGET_FILE_NAME:mpv_ohcodec_shim>"
    )
    return()
endif()

set(MPV_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/mpv-sdk")
set(MPV_LIB_DIR "${MPV_SDK_ROOT}/lib/${OHOS_ARCH}")

# FFmpeg static libs (n8.0, same build as the one inside libmpv) for direct
# libav* use in napi — e.g. muxing an audio file + video file into one output.
set(FFMPEG_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg-sdk")
set(FFMPEG_LIB_DIR "${FFMPEG_SDK_ROOT}/lib/${OHOS_ARCH}")

if(NOT EXISTS "${MPV_LIB_DIR}/libmpv.so.2")
    message(FATAL_ERROR "Missing ${MPV_LIB_DIR}/libmpv.so.2 — only arm64-v8a is vendored; x86_64 uses the stub path above.")
endif()

add_library(mpv_ohcodec_shim SHARED
    mpv_ohcodec_shim.cpp
)

add_library(mdk_napi MODULE
    player_napi.cpp
    global_napi.cpp
    media_info_napi.cpp
    mux_napi.cpp
    vpe_probe.cpp
    hwdec_probe.cpp
)

target_include_directories(mdk_napi PRIVATE "${MPV_SDK_ROOT}/include")
target_include_directories(mdk_napi PRIVATE "${FFMPEG_SDK_ROOT}/include")

target_link_libraries(mdk_napi
    ace_napi.z
    ace_ndk.z
    hilog_ndk.z
    rawfile.z
    ohfileuri
    # FFmpeg's aarch64 NEON asm addresses global data with ADRP+ADD (non-PIC).
    # In a shared lib those globals are preemptible by default, so the linker
    # rejects the relocations. -Bsymbolic binds references to symbols defined in
    # this library to the local definition (non-preemptible), letting the linker
    # resolve them at link time. This is how libmpv links the same ffmpeg .a's.
    -Wl,-Bsymbolic
    # FFmpeg static libs for muxing/remux. --start-group/--end-group resolves
    # the circular references between avformat/avcodec/avutil at link time.
    -Wl,--start-group
    "${FFMPEG_LIB_DIR}/libavformat.a"
    "${FFMPEG_LIB_DIR}/libavcodec.a"
    "${FFMPEG_LIB_DIR}/libavutil.a"
    "${FFMPEG_LIB_DIR}/libswresample.a"
    "${FFMPEG_LIB_DIR}/libdav1d.a"
    "${FFMPEG_LIB_DIR}/libxml2.a"
    "${FFMPEG_LIB_DIR}/libmbedtls.a"
    "${FFMPEG_LIB_DIR}/libmbedx509.a"
    "${FFMPEG_LIB_DIR}/libmbedcrypto.a"
    -Wl,--end-group
    z
    # libavcodec's ohdec.o (OHOS hardware decoder) references these system
    # media libs: OH_VideoDecoder_* (vdec), OH_AVBuffer_*/OH_AVFormat_* (core),
    # OH_MD_KEY_* (codecbase). libmpv links them too.
    native_media_core
    native_media_codecbase
    native_media_vdec
    # HarmonyOS Video Processing Engine (HDR color-space conversion / metadata
    # generation). Used by the VPE capability probe in vpe_probe.cpp.
    video_processing
)

add_dependencies(mdk_napi mpv_ohcodec_shim)

add_custom_command(TARGET mdk_napi POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:mpv_ohcodec_shim>"
            "$<TARGET_FILE_DIR:mdk_napi>/$<TARGET_FILE_NAME:mpv_ohcodec_shim>"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${MPV_LIB_DIR}/libmpv.so.2"
            "$<TARGET_FILE_DIR:mdk_napi>/libmpv.so.2"
)
