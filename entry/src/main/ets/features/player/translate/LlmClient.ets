import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from '../../../common/AppLog';
import { LlmTranslateConfig } from '../../../common/LlmTranslateConfig';

const logger = AppLog.getInstance('LlmClient');

interface ChatMessage {
  role: string;
  content: string;
}

interface ChatCompletionRequest {
  model: string;
  temperature: number;
  stream: boolean;
  messages: ChatMessage[];
}

/**
 * OpenAI 兼容端点（/v1/chat/completions）字幕翻译客户端（AI 字幕 P2）。
 * 用户自带 key；非流式请求；编号行协议与 gtx 引擎一致，解析容错也一致：
 * 编号优先、顺序兜底、缺失回填原文（由调用方做）。
 */
export class LlmClient {
  /**
   * 翻译一批编号字幕行，返回与输入等长的译文字符串数组。
   * 抛错 = 整批失败（网络/鉴权/响应格式），由调用方决定重试或回填。
   */
  static async translateBatch(texts: string[], targetLang: string, cfg: LlmTranslateConfig): Promise<string[]> {
    if (texts.length === 0) {
      return [];
    }
    const endpoint = LlmClient.endpointOf(cfg.baseUrl);
    const numbered = texts.map((t: string, i: number) => `${i + 1}\t${t.replace(/\r?\n/g, ' ')}`).join('\n');
    const body: ChatCompletionRequest = {
      model: cfg.model,
      temperature: 0.2,
      stream: false,
      messages: [
        {
          role: 'system',
          content: `你是字幕翻译引擎。将用户给出的带编号字幕行翻译为 ${targetLang}。`
            + '严格逐行输出 "<编号>\\t<译文>"；编号与输入一一对应；不得合并、拆分或增删行；'
            + '不输出任何解释、注释或 Markdown 代码块。'
        },
        { role: 'user', content: numbered }
      ]
    };
    const startedAt = Date.now();
    logger.info(`llm translateBatch start model=${cfg.model} lines=${texts.length} len=${numbered.length}`);

    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${cfg.apiKey}`
      },
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 60000
    };
    HttpDownloader.applyProxyToOptions(options, endpoint);
    try {
      const response = await request.request(endpoint, options);
      if (response.responseCode === 401 || response.responseCode === 403) {
        throw new Error(`auth failed (HTTP ${response.responseCode})`);
      }
      if (response.responseCode === 429) {
        throw new Error('rate limited (HTTP 429)');
      }
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const content = LlmClient.extractContent(response.result);
      const lines = LlmClient.parseNumberedLines(content, texts.length);
      logger.info(`llm translateBatch done model=${cfg.model} lines=${texts.length} parsed=${lines.filter((v) => v.length > 0).length} elapsed=${Date.now() - startedAt}ms`);
      return texts.map((t: string, i: number) => lines[i].length > 0 ? lines[i] : t);
    } catch (e) {
      const err = e as Error;
      logger.warn(`llm translateBatch failed model=${cfg.model} lines=${texts.length}: ${err.message || String(e)}`);
      throw new Error(err.message || 'llm translate failed');
    } finally {
      request.destroy();
    }
  }

  /** 设置页"测试连接"：发一条最小翻译请求验证端点/key 可用。 */
  static async testConnection(cfg: LlmTranslateConfig): Promise<void> {
    await LlmClient.translateBatch(['hello'], 'zh-CN', cfg);
  }

  private static endpointOf(baseUrl: string): string {
    const trimmed = baseUrl.trim().replace(/\/+$/, '');
    return trimmed.endsWith('/v1/chat/completions') ? trimmed : `${trimmed}/v1/chat/completions`;
  }

  private static extractContent(result: string | Object | ArrayBuffer): string {
    let text: string;
    if (typeof result === 'string') {
      text = result;
    } else if (result instanceof ArrayBuffer) {
      text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(result));
    } else {
      text = JSON.stringify(result);
    }
    const parsed = JSON.parse(text) as Record<string, Object>;
    const choices = parsed['choices'] as Array<Record<string, Object>>;
    const message = choices?.[0]?.['message'] as Record<string, Object>;
    const content = message?.['content'];
    if (typeof content !== 'string' || content.trim().length === 0) {
      throw new Error('empty llm response content');
    }
    return content;
  }

  /** 解析 "<编号><分隔><译文>" 行；分隔兼容 tab/空格/冒号/顿号/点。缺失编号按顺序填充空串。 */
  private static parseNumberedLines(content: string, expected: number): string[] {
    const out: string[] = new Array<string>(expected).fill('');
    const lineRe = /^(\d+)[\t :：.、]+([\s\S]+)$/;
    const lines = content.split(/\r?\n/);
    let nextSeq = 0;
    for (const raw of lines) {
      const line = raw.trim();
      if (line.length === 0) {
        continue;
      }
      const m = lineRe.exec(line);
      if (m) {
        const id = parseInt(m[1], 10);
        if (id >= 1 && id <= expected && out[id - 1].length === 0) {
          out[id - 1] = m[2].trim();
          nextSeq = Math.max(nextSeq, id);
          continue;
        }
      }
      // 无编号行：顺序填充到下一个空位
      while (nextSeq < expected && out[nextSeq].length > 0) {
        nextSeq++;
      }
      if (nextSeq < expected) {
        out[nextSeq] = line;
        nextSeq++;
      }
    }
    return out;
  }
}
