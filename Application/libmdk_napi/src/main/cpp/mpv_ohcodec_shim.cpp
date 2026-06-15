/*
 * libmpv's OHOS video output currently references this FFmpeg/OHCodec helper
 * without exporting a provider in the packaged shared object. Defining it here
 * lets libmpv resolve at dlopen time; the fallback is intentionally inert.
 */
extern "C" void ff_ohcodec_discard_buffer(void* /*ohcodec_buf_ptr*/) {}
