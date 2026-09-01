/*
 * asr_engine NAPI：本地 m4a/aac → 16kHz 单声道 float32 PCM 文件。
 * 链路：OH_AVSource(fd) → OH_AVDemuxer → OH_AudioCodec(AAC, 同步模式) →
 * 单声道混音 → 线性重采样 → float32 LE 写入 outPath。
 * 同步模式 = 不注册回调，Query/Get/Push/Free buffer 全流程在本 worker 线程内驱动。
 */
#include <napi/native_api.h>
#include <hilog/log.h>

#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avformat.h>

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#define ASR_LOG_TAG "asr_engine"
#define LOGI(...) OH_LOG_INFO(LOG_APP, ASR_LOG_TAG ": " __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, ASR_LOG_TAG ": " __VA_ARGS__)

namespace {

constexpr int32_t kOutSampleRate = 16000;
constexpr int64_t kQueryTimeoutUs = 20000;   // 20ms
constexpr int kMaxIdleRounds = 500;          // 防死锁兜底：连续 500 轮无输入无输出则失败退出

struct DecodeContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t fd = -1;
    int64_t offset = 0;
    int64_t size = 0;
    std::string outPath;
    // 结果
    int64_t outSamples = 0;
    std::string error;
};

/** 流式线性重采样器：任意输入采样率 → 16kHz，输入为单声道 int16，输出 float32 追加写文件。 */
class StreamingResampler {
public:
    explicit StreamingResampler(int32_t inRate) : ratio_(static_cast<double>(inRate) / kOutSampleRate) {}

    /** 处理一段输入，返回是否成功（写盘失败为 false）。 */
    bool push(const int16_t *data, size_t count, FILE *out) {
        for (size_t n = 0; n < count; n++) {
            const double i = static_cast<double>(inputCount_);
            const float cur = static_cast<float>(data[n]);
            // 输出点 k 位于输入坐标 k*ratio_；落在 [i-1, i] 区间时插值出点
            while (nextOut_ <= i) {
                const double f = nextOut_ - (i - 1.0);
                const float v = static_cast<float>(prev_ + (cur - prev_) * f) / 32768.0f;
                if (std::fwrite(&v, sizeof(float), 1, out) != 1) {
                    return false;
                }
                outCount_++;
                nextOut_ += ratio_;
            }
            prev_ = cur;
            inputCount_++;
        }
        return true;
    }

    int64_t outCount() const { return outCount_; }

private:
    double ratio_;
    double nextOut_ = 0.0;   // 下一个输出点的输入流坐标
    float prev_ = 0.0f;
    int64_t inputCount_ = 0;
    int64_t outCount_ = 0;
};

bool readTrackAudioParams(OH_AVFormat *fmt, int32_t &sampleRate, int32_t &channels, std::string &mime) {
    char *mimeStr = nullptr;
    if (!OH_AVFormat_GetStringValue(fmt, OH_MD_KEY_CODEC_MIME, const_cast<const char **>(&mimeStr)) || !mimeStr) {
        return false;
    }
    mime = mimeStr;
    if (!OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_AUD_SAMPLE_RATE, &sampleRate)) {
        return false;
    }
    if (!OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_AUD_CHANNEL_COUNT, &channels)) {
        return false;
    }
    return true;
}

/** 同步解码主流程；返回空串表示成功，否则为错误描述。 */
std::string runDecode(DecodeContext &ctx) {
    OH_AVSource *source = OH_AVSource_CreateWithFD(ctx.fd, ctx.offset, ctx.size);
    if (!source) {
        return "avsource_create_failed";
    }
    OH_AVDemuxer *demuxer = OH_AVDemuxer_CreateWithSource(source);
    if (!demuxer) {
        OH_AVSource_Destroy(source);
        return "avdemuxer_create_failed";
    }

    std::string err;
    OH_AVCodec *decoder = nullptr;
    FILE *out = nullptr;
    int32_t audioTrack = -1;
    int32_t sampleRate = 0;
    int32_t channels = 0;

    do {
        int32_t trackCount = 0;
        {
            OH_AVFormat *srcFmt = OH_AVSource_GetSourceFormat(source);
            if (srcFmt) {
                OH_AVFormat_GetIntValue(srcFmt, OH_MD_KEY_TRACK_COUNT, &trackCount);
                OH_AVFormat_Destroy(srcFmt);
            }
        }
        for (int32_t i = 0; i < trackCount; i++) {
            OH_AVFormat *trackFmt = OH_AVSource_GetTrackFormat(source, i);
            if (!trackFmt) {
                continue;
            }
            std::string mime;
            int32_t sr = 0, ch = 0;
            bool ok = readTrackAudioParams(trackFmt, sr, ch, mime);
            OH_AVFormat_Destroy(trackFmt);
            if (ok && mime == OH_AVCODEC_MIMETYPE_AUDIO_AAC) {
                audioTrack = i;
                sampleRate = sr;
                channels = ch;
                break;
            }
        }
        if (audioTrack < 0) {
            err = "no_aac_track";
            break;
        }
        if (OH_AVDemuxer_SelectTrackByID(demuxer, audioTrack) != AV_ERR_OK) {
            err = "select_track_failed";
            break;
        }

        decoder = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_AAC, false);
        if (!decoder) {
            err = "decoder_create_failed";
            break;
        }
        OH_AVFormat *decFmt = OH_AVFormat_Create();
        OH_AVFormat_SetStringValue(decFmt, OH_MD_KEY_CODEC_MIME, OH_AVCODEC_MIMETYPE_AUDIO_AAC);
        OH_AVFormat_SetIntValue(decFmt, OH_MD_KEY_AUD_SAMPLE_RATE, sampleRate);
        OH_AVFormat_SetIntValue(decFmt, OH_MD_KEY_AUD_CHANNEL_COUNT, channels);
        OH_AVErrCode cfgRet = OH_AudioCodec_Configure(decoder, decFmt);
        OH_AVFormat_Destroy(decFmt);
        if (cfgRet != AV_ERR_OK) {
            err = "decoder_configure_failed";
            break;
        }
        if (OH_AudioCodec_Prepare(decoder) != AV_ERR_OK) {
            err = "decoder_prepare_failed";
            break;
        }
        if (OH_AudioCodec_Start(decoder) != AV_ERR_OK) {
            err = "decoder_start_failed";
            break;
        }

        out = std::fopen(ctx.outPath.c_str(), "wb");
        if (!out) {
            err = "open_output_failed";
            break;
        }

        StreamingResampler resampler(sampleRate);
        std::vector<int16_t> mono;
        bool inputEos = false;
        bool outputEos = false;
        int idleRounds = 0;

        while (!outputEos) {
            bool progressed = false;
            // —— 输入：解封装一个样本并送入解码器 ——
            if (!inputEos) {
                uint32_t inIdx = 0;
                if (OH_AudioCodec_QueryInputBuffer(decoder, &inIdx, 0) == AV_ERR_OK) {
                    OH_AVBuffer *inBuf = OH_AudioCodec_GetInputBuffer(decoder, inIdx);
                    if (!inBuf) {
                        err = "get_input_buffer_failed";
                        break;
                    }
                    OH_AVErrCode readRet = OH_AVDemuxer_ReadSampleBuffer(demuxer, audioTrack, inBuf);
                    OH_AVCodecBufferAttr attr = {};
                    if (readRet == AV_ERR_OK) {
                        OH_AVBuffer_GetBufferAttr(inBuf, &attr);
                    } else {
                        // 解封装 EOF：用 EOS 标记的空输入结束解码
                        attr.size = 0;
                        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
                        inputEos = true;
                    }
                    OH_AVBuffer_SetBufferAttr(inBuf, &attr);
                    OH_AudioCodec_PushInputBuffer(decoder, inIdx);
                    progressed = true;
                }
            }
            // —— 输出：取一帧解码 PCM ——
            uint32_t outIdx = 0;
            OH_AVErrCode qRet = OH_AudioCodec_QueryOutputBuffer(decoder, &outIdx, kQueryTimeoutUs);
            if (qRet == AV_ERR_OK) {
                OH_AVBuffer *outBuf = OH_AudioCodec_GetOutputBuffer(decoder, outIdx);
                if (outBuf) {
                    OH_AVCodecBufferAttr attr = {};
                    if (OH_AVBuffer_GetBufferAttr(outBuf, &attr) == AV_ERR_OK && attr.size > 0) {
                        const int16_t *pcm = reinterpret_cast<const int16_t *>(
                            OH_AVBuffer_GetAddr(outBuf) + attr.offset);
                        const size_t frames = static_cast<size_t>(attr.size) / sizeof(int16_t) / channels;
                        mono.resize(frames);
                        for (size_t f = 0; f < frames; f++) {
                            int32_t acc = 0;
                            for (int32_t c = 0; c < channels; c++) {
                                acc += pcm[f * channels + c];
                            }
                            mono[f] = static_cast<int16_t>(acc / channels);
                        }
                        if (!resampler.push(mono.data(), frames, out)) {
                            err = "write_output_failed";
                        }
                    }
                    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
                        outputEos = true;
                    }
                    OH_AudioCodec_FreeOutputBuffer(decoder, outIdx);
                    progressed = true;
                }
            }
            if (!err.empty()) {
                break;
            }
            if (!progressed) {
                if (++idleRounds > kMaxIdleRounds) {
                    err = "decode_stalled";
                    break;
                }
            } else {
                idleRounds = 0;
            }
        }
        ctx.outSamples = resampler.outCount();
    } while (false);

    if (out) {
        std::fflush(out);
        std::fclose(out);
    }
    if (decoder) {
        OH_AudioCodec_Stop(decoder);
        OH_AudioCodec_Destroy(decoder);
    }
    OH_AVDemuxer_Destroy(demuxer);
    OH_AVSource_Destroy(source);
    return err;
}

void decodeExecute(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<DecodeContext *>(data);
    ctx->error = runDecode(*ctx);
    if (ctx->error.empty()) {
        LOGI("decode done samples=%lld out=%s", (long long)ctx->outSamples, ctx->outPath.c_str());
    } else {
        LOGE("decode failed: %s", ctx->error.c_str());
    }
}

void decodeComplete(napi_env env, napi_status status, void *data) {
    auto *ctx = static_cast<DecodeContext *>(data);
    if (status == napi_ok && ctx->error.empty()) {
        napi_value result;
        napi_create_int64(env, ctx->outSamples, &result);
        napi_resolve_deferred(env, ctx->deferred, result);
    } else {
        napi_value err;
        napi_create_string_utf8(env, ctx->error.empty() ? "napi_work_failed" : ctx->error.c_str(),
                                NAPI_AUTO_LENGTH, &err);
        napi_reject_deferred(env, ctx->deferred, err);
    }
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

napi_value decodeAacToPcm16k(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_error(env, "invalid_args", "decodeAacToPcm16k(fd, offset, size, outPath)");
        return nullptr;
    }
    auto *ctx = new DecodeContext();
    ctx->env = env;
    napi_get_value_int32(env, args[0], &ctx->fd);
    napi_get_value_int64(env, args[1], &ctx->offset);
    napi_get_value_int64(env, args[2], &ctx->size);
    size_t pathLen = 0;
    napi_get_value_string_utf8(env, args[3], nullptr, 0, &pathLen);
    ctx->outPath.resize(pathLen);
    napi_get_value_string_utf8(env, args[3], ctx->outPath.data(), pathLen + 1, &pathLen);

    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_value workName;
    napi_create_string_utf8(env, "asr_decode", NAPI_AUTO_LENGTH, &workName);
    napi_create_async_work(env, nullptr, workName, decodeExecute, decodeComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"decodeAacToPcm16k", nullptr, decodeAacToPcm16k, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module gAsrEngineModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = init,
    .nm_modname = "asr_engine",
    .nm_priv = nullptr,
    .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor)) void registerAsrEngineModule() {
    napi_module_register(&gAsrEngineModule);
}
