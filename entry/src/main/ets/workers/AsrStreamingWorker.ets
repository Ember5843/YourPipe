import { worker, ThreadWorkerGlobalScope, MessageEvents } from '@kit.ArkTS';
import {
  OnlineRecognizer, OnlineRecognizerConfig, OnlineStream
} from 'sherpa_onnx';

/**
 * 流式 ASR worker（P3 live）：独占 OnlineRecognizer + 单条 OnlineStream
 * （sherpa 句柄不可跨线程，识别器只能在本 worker 线程内创建与使用）。
 * 模型：streaming zipformer bilingual zh-en（真流式 transducer，逐 token 出字）。
 *
 * 宿主 → worker：
 *   { cmd: 'init', encoder, decoder, joiner, tokens } → 回 { type: 'ready' } / { type: 'error' }
 *   { cmd: 'feed', samples: ArrayBuffer(float32 16kHz mono), endPtsMs } → 回 partial/final
 *   { cmd: 'resetStream' }  播放断连（seek/源切换）：丢弃当前句状态，下一段重新起句
 *   { cmd: 'flush', endPtsMs }  EOF：冲刷残余音频，尽量出最后一次 final
 * worker → 宿主：
 *   { type: 'partial', text, endPtsMs }  未定点：当前句识别快照（随音频生长/改写）
 *   { type: 'final', text, endPtsMs }    端点命中：一句定稿
 *   { type: 'ready' } / { type: 'error', message }
 */

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

interface WorkerCmd {
  cmd: string;
  encoder: string;
  decoder: string;
  joiner: string;
  tokens: string;
  samples: ArrayBuffer;
  endPtsMs: number;
}

let recognizer: OnlineRecognizer | null = null;
let stream: OnlineStream | null = null;

function postError(stage: string, e: Object): void {
  const err = e as Error;
  workerPort.postMessage({ type: 'error', message: `${stage}: ${err.message || String(e)}` });
}

function handleInit(msg: WorkerCmd): void {
  try {
    const config = new OnlineRecognizerConfig();
    config.featConfig.sampleRate = 16000;
    config.featConfig.featureDim = 80;
    config.modelConfig.transducer.encoder = msg.encoder;
    config.modelConfig.transducer.decoder = msg.decoder;
    config.modelConfig.transducer.joiner = msg.joiner;
    config.modelConfig.tokens = msg.tokens;
    config.modelConfig.numThreads = 2;
    config.modelConfig.debug = false;
    config.decodingMethod = 'greedy_search';
    config.enableEndpoint = true;
    // 字幕场景：句尾静音 1.2s 即定句（rule2）；无静音单句最长 20s 强制切（rule3）
    config.rule1MinTrailingSilence = 2.4;
    config.rule2MinTrailingSilence = 1.2;
    config.rule3MinUtteranceLength = 20;
    recognizer = new OnlineRecognizer(config);
    stream = recognizer.createStream();
    workerPort.postMessage({ type: 'ready' });
  } catch (e) {
    postError('init', e as Object);
  }
}

function handleFeed(msg: WorkerCmd): void {
  if (!recognizer || !stream) {
    return;
  }
  try {
    const samples = new Float32Array(msg.samples);
    if (samples.length === 0) {
      return;
    }
    stream.acceptWaveform({ samples: samples, sampleRate: 16000 });
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    if (recognizer.isEndpoint(stream)) {
      const text = recognizer.getResult(stream).text.trim();
      // 端点命中必须 reset（空文本也要），否则下一句会接着旧状态识别
      recognizer.reset(stream);
      if (text.length > 0) {
        workerPort.postMessage({ type: 'final', text: text, endPtsMs: msg.endPtsMs });
      }
    } else {
      const text = recognizer.getResult(stream).text.trim();
      workerPort.postMessage({ type: 'partial', text: text, endPtsMs: msg.endPtsMs });
    }
  } catch (e) {
    postError('feed', e as Object);
  }
}

function handleFlush(endPtsMs: number): void {
  if (!recognizer || !stream) {
    return;
  }
  try {
    stream.inputFinished();
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    const text = recognizer.getResult(stream).text.trim();
    recognizer.reset(stream);
    if (text.length > 0) {
      workerPort.postMessage({ type: 'final', text: text, endPtsMs: endPtsMs });
    }
  } catch (e) {
    postError('flush', e as Object);
  }
}

workerPort.onmessage = (e: MessageEvents): void => {
  const data = e.data as WorkerCmd;
  switch (data.cmd) {
    case 'init':
      handleInit(data);
      break;
    case 'feed':
      handleFeed(data);
      break;
    case 'resetStream':
      if (recognizer && stream) {
        recognizer.reset(stream);
      }
      break;
    case 'flush':
      handleFlush(data.endPtsMs);
      break;
    default:
      break;
  }
};
