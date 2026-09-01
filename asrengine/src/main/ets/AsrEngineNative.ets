import asrEngine from 'libasr_engine.so';

/**
 * 把本地 m4a/aac 文件（fd 传入）解码重采样为 16kHz 单声道 float32 PCM，
 * 写入 outPath（小端 float32 原始流）。resolve 值为输出采样点数。
 * reject 原因以字符串错误码/信息给出（demux/decode/io）。
 */
export function decodeAacToPcm16k(fd: number, offset: number, size: number, outPath: string): Promise<number> {
  return asrEngine.decodeAacToPcm16k(fd, offset, size, outPath);
}
