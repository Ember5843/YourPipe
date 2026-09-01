// asrengine 公共出口：端侧 ASR 音频解码（系统 NDK 解封装 + AAC 解码 → 16kHz 单声道 float PCM 文件）。
export { decodeAacToPcm16k } from './src/main/ets/AsrEngineNative';
