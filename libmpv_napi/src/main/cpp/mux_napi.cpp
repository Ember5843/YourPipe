/*
 * Audio/video muxing module — see mux_napi.h.
 *
 * Implements muxAudioVideo(videoPath, audioPath, outPath): copies the first
 * video stream from videoPath and the first audio stream from audioPath into a
 * single output file, without re-encoding. On failure throws a JS Error whose
 * message describes what went wrong (native style, like @sj/ffmpeg).
 */
#include "mux_napi.h"

#include <filemanagement/file_uri/oh_file_uri.h>
#include <hilog/log.h>

#include <cstdlib>
#include <string>
#include <vector>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
}

namespace {

#undef LOG_TAG
#define MUX_LOG(fmt, ...) \
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mux", fmt, ##__VA_ARGS__)

std::string AvErr(int err)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof(buf));
    return buf;
}

std::string GetString(napi_env env, napi_value v)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
        return {};
    }
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

// DocumentPicker hands back "file://docs/..." URIs, but libavformat wants a
// real filesystem path. Resolve file:// URIs; pass anything else through.
std::string ResolveUri(const std::string& url)
{
    if (url.rfind("file://", 0) != 0) {
        return url;
    }
    char* realPath = nullptr;
    FileManagement_ErrCode err =
        OH_FileUri_GetPathFromUri(url.c_str(), static_cast<unsigned int>(url.size()), &realPath);
    if (err == ERR_OK && realPath != nullptr) {
        std::string resolved(realPath);
        free(realPath);
        return resolved;
    }
    if (realPath) free(realPath);
    return url;
}

// Throwable error carrying a human-readable message (native style).
struct MuxError {
    std::string message;
};

// One opened input: its format context and the index of the stream we copy.
struct Input {
    AVFormatContext* fmt = nullptr;
    int streamIndex = -1;
    ~Input() { if (fmt) avformat_close_input(&fmt); }
};

// Open `path` and locate the first stream of `type`. Throws MuxError on failure.
void OpenInput(Input& in, const std::string& path, AVMediaType type)
{
    // SABR dumps are fMP4 (init + moof/mdat). Give lavf room to probe fragments.
    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "probesize", "10000000", 0);
    av_dict_set(&opts, "analyzeduration", "10000000", 0);
    int ret = avformat_open_input(&in.fmt, path.c_str(), nullptr, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        throw MuxError{"open input failed (" + path + "): " + AvErr(ret)};
    }
    ret = avformat_find_stream_info(in.fmt, nullptr);
    if (ret < 0) {
        throw MuxError{"find stream info failed (" + path + "): " + AvErr(ret)};
    }
    in.streamIndex = av_find_best_stream(in.fmt, type, -1, -1, nullptr, 0);
    if (in.streamIndex < 0) {
        const char* what = (type == AVMEDIA_TYPE_VIDEO) ? "video" : "audio";
        throw MuxError{std::string("no ") + what + " stream in " + path};
    }
    AVStream* st = in.fmt->streams[in.streamIndex];
    MUX_LOG("open %{public}s type=%{public}s codec=%{public}d tb=%{public}d/%{public}d "
            "frames=%{public}lld duration=%{public}lld",
            path.c_str(),
            type == AVMEDIA_TYPE_VIDEO ? "video" : "audio",
            st->codecpar ? st->codecpar->codec_id : 0,
            st->time_base.num, st->time_base.den,
            static_cast<long long>(st->nb_frames),
            static_cast<long long>(st->duration));
}

// Remux: copy video stream from videoPath + audio stream from audioPath into
// outPath. Container is chosen from outPath's extension. Throws MuxError.
// A/V packets are interleaved by DTS so progressive players do not black-screen.
void DoMux(const std::string& videoPath, const std::string& audioPath,
           const std::string& outPath)
{
    Input video, audio;
    OpenInput(video, videoPath, AVMEDIA_TYPE_VIDEO);
    OpenInput(audio, audioPath, AVMEDIA_TYPE_AUDIO);

    AVFormatContext* out = nullptr;
    int ret = avformat_alloc_output_context2(&out, nullptr, nullptr, outPath.c_str());
    if (ret < 0 || !out) {
        throw MuxError{"cannot infer output format from " + outPath + ": " + AvErr(ret)};
    }

    // Map: out stream 0 <- video input, out stream 1 <- audio input.
    struct StreamMap {
        Input* in;
        int outIndex;
        AVPacket* peek;  // next packet waiting for interleave, or null when EOF
        bool eof;
    };
    std::vector<StreamMap> maps;
    for (Input* in : {&video, &audio}) {
        AVStream* src = in->fmt->streams[in->streamIndex];
        AVStream* dst = avformat_new_stream(out, nullptr);
        if (!dst) {
            avformat_free_context(out);
            throw MuxError{"failed to allocate output stream"};
        }
        ret = avcodec_parameters_copy(dst->codecpar, src->codecpar);
        if (ret < 0) {
            avformat_free_context(out);
            throw MuxError{"failed to copy codec parameters: " + AvErr(ret)};
        }
        dst->codecpar->codec_tag = 0;  // let the muxer pick a valid tag
        dst->time_base = src->time_base;
        if (src->avg_frame_rate.num > 0 && src->avg_frame_rate.den > 0) {
            dst->avg_frame_rate = src->avg_frame_rate;
            dst->r_frame_rate = src->r_frame_rate.num > 0 ? src->r_frame_rate : src->avg_frame_rate;
        }
        maps.push_back({in, dst->index, nullptr, false});
    }

    // Open the output file (unless the muxer is buffer-only).
    if (!(out->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out->pb, outPath.c_str(), AVIO_FLAG_WRITE);
        if (ret < 0) {
            avformat_free_context(out);
            throw MuxError{"cannot open output file " + outPath + ": " + AvErr(ret)};
        }
    }
    // Progressive MP4: move moov to the front so players can start immediately.
    AVDictionary* muxOpts = nullptr;
    if (out->oformat && out->oformat->name &&
        (std::string(out->oformat->name).find("mp4") != std::string::npos ||
         std::string(out->oformat->name).find("mov") != std::string::npos ||
         std::string(out->oformat->name).find("ismv") != std::string::npos)) {
        av_dict_set(&muxOpts, "movflags", "+faststart", 0);
    }
    ret = avformat_write_header(out, &muxOpts);
    av_dict_free(&muxOpts);
    if (ret < 0) {
        if (!(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
        avformat_free_context(out);
        throw MuxError{"write header failed: " + AvErr(ret)};
    }

    auto readNext = [](StreamMap& m) -> bool {
        if (m.eof) {
            return false;
        }
        if (!m.peek) {
            m.peek = av_packet_alloc();
            if (!m.peek) {
                m.eof = true;
                return false;
            }
        }
        while (true) {
            int r = av_read_frame(m.in->fmt, m.peek);
            if (r < 0) {
                av_packet_free(&m.peek);
                m.peek = nullptr;
                m.eof = true;
                return false;
            }
            if (m.peek->stream_index == m.in->streamIndex) {
                return true;
            }
            av_packet_unref(m.peek);
        }
    };

    // Prime one packet from each input.
    for (StreamMap& m : maps) {
        readNext(m);
    }

    std::string failure;
    int64_t videoPkts = 0;
    int64_t audioPkts = 0;
    while (!maps[0].eof || !maps[1].eof) {
        // Pick the stream whose next packet has the smaller DTS (in seconds).
        int pick = -1;
        double bestTs = 0;
        for (size_t i = 0; i < maps.size(); ++i) {
            if (maps[i].eof || !maps[i].peek) {
                continue;
            }
            AVStream* src = maps[i].in->fmt->streams[maps[i].in->streamIndex];
            int64_t ts = maps[i].peek->dts != AV_NOPTS_VALUE
                ? maps[i].peek->dts
                : (maps[i].peek->pts != AV_NOPTS_VALUE ? maps[i].peek->pts : 0);
            double sec = ts * av_q2d(src->time_base);
            if (pick < 0 || sec < bestTs) {
                pick = static_cast<int>(i);
                bestTs = sec;
            }
        }
        if (pick < 0) {
            break;
        }

        StreamMap& m = maps[static_cast<size_t>(pick)];
        AVStream* src = m.in->fmt->streams[m.in->streamIndex];
        AVStream* dst = out->streams[m.outIndex];
        AVPacket* pkt = m.peek;
        m.peek = nullptr;

        av_packet_rescale_ts(pkt, src->time_base, dst->time_base);
        pkt->stream_index = m.outIndex;
        pkt->pos = -1;
        if (pkt->duration < 0) {
            pkt->duration = 0;
        }
        int wret = av_interleaved_write_frame(out, pkt);
        av_packet_free(&pkt);
        if (wret < 0) {
            failure = "write frame failed: " + AvErr(wret);
            break;
        }
        if (pick == 0) {
            videoPkts++;
        } else {
            audioPkts++;
        }
        readNext(m);
    }

    // Drain leftovers if interleave loop exited early on one side only.
    if (failure.empty()) {
        for (size_t i = 0; i < maps.size(); ++i) {
            StreamMap& m = maps[i];
            while (!m.eof) {
                if (!m.peek && !readNext(m)) {
                    break;
                }
                if (!m.peek) {
                    break;
                }
                AVStream* src = m.in->fmt->streams[m.in->streamIndex];
                AVStream* dst = out->streams[m.outIndex];
                AVPacket* pkt = m.peek;
                m.peek = nullptr;
                av_packet_rescale_ts(pkt, src->time_base, dst->time_base);
                pkt->stream_index = m.outIndex;
                pkt->pos = -1;
                int wret = av_interleaved_write_frame(out, pkt);
                av_packet_free(&pkt);
                if (wret < 0) {
                    failure = "write frame failed: " + AvErr(wret);
                    break;
                }
                if (i == 0) {
                    videoPkts++;
                } else {
                    audioPkts++;
                }
                readNext(m);
            }
            if (!failure.empty()) {
                break;
            }
        }
    }

    for (StreamMap& m : maps) {
        if (m.peek) {
            av_packet_free(&m.peek);
            m.peek = nullptr;
        }
    }

    if (failure.empty() && videoPkts == 0) {
        failure = "no video packets remuxed (black screen risk)";
    }
    if (failure.empty() && audioPkts == 0) {
        failure = "no audio packets remuxed";
    }

    if (failure.empty()) {
        ret = av_write_trailer(out);
        if (ret < 0) failure = "write trailer failed: " + AvErr(ret);
    }
    if (!(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
    avformat_free_context(out);
    MUX_LOG("mux done: %{public}s + %{public}s -> %{public}s vPkts=%{public}lld aPkts=%{public}lld (%{public}s)",
            videoPath.c_str(), audioPath.c_str(), outPath.c_str(),
            static_cast<long long>(videoPkts), static_cast<long long>(audioPkts),
            failure.empty() ? "ok" : failure.c_str());
    if (!failure.empty()) throw MuxError{failure};
}

// napi entry: muxAudioVideo(videoPath, audioPath, outPath): void
// Runs synchronously on the calling thread — wrap it in an ArkTS TaskPool task
// for background execution. Throws a JS Error (message describes the failure).
napi_value MuxAudioVideo(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_error(env, nullptr, "muxAudioVideo: expected (videoPath, audioPath, outPath)");
        return nullptr;
    }
    std::string videoPath = ResolveUri(GetString(env, args[0]));
    std::string audioPath = ResolveUri(GetString(env, args[1]));
    std::string outPath = ResolveUri(GetString(env, args[2]));
    if (videoPath.empty() || audioPath.empty() || outPath.empty()) {
        napi_throw_error(env, nullptr, "muxAudioVideo: paths must be non-empty");
        return nullptr;
    }
    try {
        DoMux(videoPath, audioPath, outPath);
    } catch (const MuxError& e) {
        napi_throw_error(env, nullptr, e.message.c_str());
        return nullptr;
    }
    return nullptr;
}

}  // namespace

void RegisterMuxModule(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"muxAudioVideo", nullptr, MuxAudioVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, std::size(desc), desc);
}

