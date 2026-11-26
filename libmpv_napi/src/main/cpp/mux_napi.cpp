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
#include <memory>
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

std::vector<std::string> GetStringArray(napi_env env, napi_value v)
{
    std::vector<std::string> out;
    bool isArray = false;
    if (!v || napi_is_array(env, v, &isArray) != napi_ok || !isArray) {
        return out;
    }
    uint32_t len = 0;
    if (napi_get_array_length(env, v, &len) != napi_ok) {
        return out;
    }
    out.reserve(len);
    for (uint32_t i = 0; i < len; ++i) {
        napi_value elem = nullptr;
        if (napi_get_element(env, v, i, &elem) == napi_ok && elem != nullptr) {
            out.push_back(GetString(env, elem));
        } else {
            out.emplace_back();
        }
    }
    return out;
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

const char* MediaTypeLabel(AVMediaType type)
{
    if (type == AVMEDIA_TYPE_VIDEO) return "video";
    if (type == AVMEDIA_TYPE_AUDIO) return "audio";
    if (type == AVMEDIA_TYPE_SUBTITLE) return "subtitle";
    return "other";
}

// Open `path` and locate the first stream of `type`. Returns false when missing if allowMissing is true.
bool OpenInputStream(Input& in, const std::string& path, AVMediaType type, bool allowMissing)
{
    AVDictionary* opts = nullptr;
    if (type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO) {
        // SABR dumps are fMP4 (init + moof/mdat). Give lavf room to probe fragments.
        av_dict_set(&opts, "probesize", "10000000", 0);
        av_dict_set(&opts, "analyzeduration", "10000000", 0);
    }
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
        if (allowMissing) {
            return false;
        }
        throw MuxError{std::string("no ") + MediaTypeLabel(type) + " stream in " + path};
    }
    AVStream* st = in.fmt->streams[in.streamIndex];
    MUX_LOG("open %{public}s type=%{public}s codec=%{public}d tb=%{public}d/%{public}d "
            "frames=%{public}lld duration=%{public}lld",
            path.c_str(),
            MediaTypeLabel(type),
            st->codecpar ? st->codecpar->codec_id : 0,
            st->time_base.num, st->time_base.den,
            static_cast<long long>(st->nb_frames),
            static_cast<long long>(st->duration));
    return true;
}

// Remux: copy video stream + optional audio stream (or inline audio when audioPath is empty)
// + zero or more subtitle tracks into outPath. Container is chosen from outPath's extension.
// All packets are interleaved by DTS/PTS without re-encoding.
void DoMuxMedia(
    const std::string& videoPath,
    const std::string& audioPath,
    const std::vector<std::string>& subtitlePaths,
    const std::vector<std::string>& subtitleLangs,
    const std::vector<std::string>& subtitleTitles,
    const std::string& outPath)
{
    Input video;
    Input externalAudio;
    Input inlineAudio;
    std::vector<std::unique_ptr<Input>> subInputs;

    OpenInputStream(video, videoPath, AVMEDIA_TYPE_VIDEO, false);

    struct StreamMap {
        Input* in;
        AVMediaType mediaType;
        int outIndex;
        AVPacket* peek;  // next packet waiting for interleave, or null when EOF
        bool eof;
    };
    struct PendingSource {
        Input* in;
        AVMediaType mediaType;
        std::string lang;
        std::string title;
        bool isDefaultSub;
    };
    std::vector<PendingSource> sources;
    sources.push_back({&video, AVMEDIA_TYPE_VIDEO, {}, {}, false});

    bool expectAudio = false;
    if (!audioPath.empty()) {
        OpenInputStream(externalAudio, audioPath, AVMEDIA_TYPE_AUDIO, false);
        sources.push_back({&externalAudio, AVMEDIA_TYPE_AUDIO, {}, {}, false});
        expectAudio = true;
    } else if (OpenInputStream(inlineAudio, videoPath, AVMEDIA_TYPE_AUDIO, true)) {
        sources.push_back({&inlineAudio, AVMEDIA_TYPE_AUDIO, {}, {}, false});
        expectAudio = true;
    }

    size_t subCountAdded = 0;
    for (size_t i = 0; i < subtitlePaths.size(); ++i) {
        const std::string& subPath = subtitlePaths[i];
        if (subPath.empty()) {
            continue;
        }
        auto sub = std::make_unique<Input>();
        OpenInputStream(*sub, subPath, AVMEDIA_TYPE_SUBTITLE, false);
        std::string lang = i < subtitleLangs.size() ? subtitleLangs[i] : "";
        std::string title = i < subtitleTitles.size() ? subtitleTitles[i] : "";
        sources.push_back({sub.get(), AVMEDIA_TYPE_SUBTITLE, lang, title, subCountAdded == 0});
        subInputs.push_back(std::move(sub));
        subCountAdded++;
    }

    AVFormatContext* out = nullptr;
    int ret = avformat_alloc_output_context2(&out, nullptr, nullptr, outPath.c_str());
    if (ret < 0 || !out) {
        throw MuxError{"cannot infer output format from " + outPath + ": " + AvErr(ret)};
    }

    std::vector<StreamMap> maps;
    for (const PendingSource& srcDesc : sources) {
        AVStream* src = srcDesc.in->fmt->streams[srcDesc.in->streamIndex];
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
        if (srcDesc.mediaType == AVMEDIA_TYPE_VIDEO &&
            src->avg_frame_rate.num > 0 && src->avg_frame_rate.den > 0) {
            dst->avg_frame_rate = src->avg_frame_rate;
            dst->r_frame_rate = src->r_frame_rate.num > 0 ? src->r_frame_rate : src->avg_frame_rate;
        }
        if (srcDesc.mediaType == AVMEDIA_TYPE_SUBTITLE) {
            if (!srcDesc.lang.empty()) {
                av_dict_set(&dst->metadata, "language", srcDesc.lang.c_str(), 0);
            }
            if (!srcDesc.title.empty()) {
                av_dict_set(&dst->metadata, "title", srcDesc.title.c_str(), 0);
            }
            if (srcDesc.isDefaultSub) {
                dst->disposition |= AV_DISPOSITION_DEFAULT;
            }
        }
        maps.push_back({srcDesc.in, srcDesc.mediaType, dst->index, nullptr, false});
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

    auto anyAlive = [&maps]() -> bool {
        for (const StreamMap& m : maps) {
            if (!m.eof) return true;
        }
        return false;
    };

    // Prime one packet from each input.
    for (StreamMap& m : maps) {
        readNext(m);
    }

    std::string failure;
    int64_t videoPkts = 0;
    int64_t audioPkts = 0;
    int64_t subPkts = 0;
    while (anyAlive()) {
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

        if (pkt->dts == AV_NOPTS_VALUE && pkt->pts != AV_NOPTS_VALUE) {
            pkt->dts = pkt->pts;
        } else if (pkt->pts == AV_NOPTS_VALUE && pkt->dts != AV_NOPTS_VALUE) {
            pkt->pts = pkt->dts;
        }
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
        if (m.mediaType == AVMEDIA_TYPE_VIDEO) {
            videoPkts++;
        } else if (m.mediaType == AVMEDIA_TYPE_AUDIO) {
            audioPkts++;
        } else if (m.mediaType == AVMEDIA_TYPE_SUBTITLE) {
            subPkts++;
        }
        readNext(m);
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
    if (failure.empty() && expectAudio && audioPkts == 0) {
        failure = "no audio packets remuxed";
    }

    if (failure.empty()) {
        ret = av_write_trailer(out);
        if (ret < 0) failure = "write trailer failed: " + AvErr(ret);
    }
    if (!(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
    avformat_free_context(out);
    MUX_LOG("mux done: %{public}s + %{public}s + subs=%{public}zu -> %{public}s "
            "vPkts=%{public}lld aPkts=%{public}lld sPkts=%{public}lld (%{public}s)",
            videoPath.c_str(), audioPath.empty() ? "(inline/none)" : audioPath.c_str(),
            subCountAdded, outPath.c_str(),
            static_cast<long long>(videoPkts), static_cast<long long>(audioPkts),
            static_cast<long long>(subPkts),
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
        DoMuxMedia(videoPath, audioPath, {}, {}, {}, outPath);
    } catch (const MuxError& e) {
        napi_throw_error(env, nullptr, e.message.c_str());
        return nullptr;
    }
    return nullptr;
}

// napi entry: muxMedia(videoPath, audioPath, subtitlePaths, subtitleLangs, subtitleTitles, outPath): void
napi_value MuxMedia(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 6) {
        napi_throw_error(env, nullptr,
            "muxMedia: expected (videoPath, audioPath, subtitlePaths, subtitleLangs, subtitleTitles, outPath)");
        return nullptr;
    }
    std::string videoPath = ResolveUri(GetString(env, args[0]));
    std::string audioPath = ResolveUri(GetString(env, args[1]));
    std::vector<std::string> subPathsRaw = GetStringArray(env, args[2]);
    std::vector<std::string> subPaths;
    subPaths.reserve(subPathsRaw.size());
    for (const std::string& p : subPathsRaw) {
        subPaths.push_back(ResolveUri(p));
    }
    std::vector<std::string> subLangs = GetStringArray(env, args[3]);
    std::vector<std::string> subTitles = GetStringArray(env, args[4]);
    std::string outPath = ResolveUri(GetString(env, args[5]));
    if (videoPath.empty() || outPath.empty()) {
        napi_throw_error(env, nullptr, "muxMedia: videoPath and outPath must be non-empty");
        return nullptr;
    }
    try {
        DoMuxMedia(videoPath, audioPath, subPaths, subLangs, subTitles, outPath);
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
        {"muxMedia", nullptr, MuxMedia, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, std::size(desc), desc);
}

