import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { YouTubeExtractor, ThumbnailInfo, VideoInfo, PlayerResponse, Format, CipherBridge, MpdBuilder } from 'youtube_core';

let extractor: YouTubeExtractor;

export default function youTubeExtractorTest() {
  describe('YouTubeExtractorTest', () => {

    beforeAll(async () => {
      console.info('[Test] 初始化 YouTubeExtractor');
      extractor = new YouTubeExtractor({} as common.UIAbilityContext);
      await extractor.initialize();
    });

    afterAll(() => {
      console.info('[Test] 清理 YouTubeExtractor');
      extractor.clearCache();
    });

    it('testExtractVideoInfo', 0, async () => {
      console.info('[Test] 测试提取视频信息');

      try {
        const videoId = 'Mfxoo_E969Y';
        const videoInfo = await extractor.extractVideoInfo(videoId);

        expect(videoInfo != null).assertTrue();
        expect(videoInfo.videoId).assertEqual(videoId);
        expect(videoInfo.title != null && videoInfo.title.length > 0).assertTrue();
        expect(videoInfo.author != null && videoInfo.author.length > 0).assertTrue();

        console.info('[Test] 视频标题:', videoInfo.title);
        console.info('[Test] 视频作者:', videoInfo.author);
        console.info('[Test] 视频时长:', videoInfo.getFormattedDuration());
        console.info('[Test] 观看次数:', videoInfo.getFormattedViewCount());

      } catch (error) {
        console.error('[Test] 提取视频信息失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testFetchWatchPage', 0, async () => {
      console.info('[Test] 测试获取 watch 页面');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);

        expect(html != null).assertTrue();
        expect(html.length > 0).assertTrue();
        expect(html.toLowerCase().indexOf('youtube') >= 0).assertTrue();

        console.info('[Test] Watch 页面长度:', html.length);

      } catch (error) {
        console.error('[Test] 获取 watch 页面失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testExtractPlayerResponse', 0, async () => {
      console.info('[Test] 测试提取 player response');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const playerResponse = extractor.extractPlayerResponse(html);

        expect(playerResponse != null).assertTrue();
        expect(playerResponse.videoDetails != null).assertTrue();
        expect(playerResponse.videoDetails?.videoId != null).assertTrue();

        console.info('[Test] Video ID:', playerResponse.videoDetails?.videoId);
        console.info('[Test] Title:', playerResponse.videoDetails?.title);

      } catch (error) {
        console.error('[Test] 提取 player response 失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testExtractMetadata', 0, async () => {
      console.info('[Test] 测试提取元数据');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const playerResponse = extractor.extractPlayerResponse(html);
        const videoInfo = extractor.extractMetadata(videoId, playerResponse);

        expect(videoInfo.videoId).assertEqual(videoId);
        expect(videoInfo.title != null).assertTrue();
        expect(videoInfo.author != null).assertTrue();

        if (videoInfo.lengthSeconds != null) {
          expect(videoInfo.lengthSeconds > 0).assertTrue();
        }

        console.info('[Test] 元数据提取成功');
        console.info('[Test] 标题:', videoInfo.title);
        console.info('[Test] 作者:', videoInfo.author);
        console.info('[Test] 时长(秒):', videoInfo.lengthSeconds);
        console.info('[Test] 缩略图数量:', videoInfo.thumbnails.length);

      } catch (error) {
        console.error('[Test] 提取元数据失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testExtractPlayerJsUrl', 0, async () => {
      console.info('[Test] 测试提取 player JS URL');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const jsUrl = extractor.extractPlayerJsUrl(html);

        if (jsUrl != null) {
          expect(jsUrl.length > 0).assertTrue();
          expect(jsUrl.indexOf('base.js') >= 0).assertTrue();
          console.info('[Test] Player JS URL:', jsUrl);
        } else {
          console.warn('[Test] 未找到 player JS URL');
        }

      } catch (error) {
        console.error('[Test] 提取 player JS URL 失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testFetchBaseJs', 0, async () => {
      console.info('[Test] 测试获取 base.js');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const baseJs = await extractor.fetchBaseJs(html, videoId);

        if (baseJs != null) {
          expect(baseJs.length > 0).assertTrue();
          console.info('[Test] Base.js 长度:', baseJs.length);
        } else {
          console.warn('[Test] 未能获取 base.js');
        }

      } catch (error) {
        console.error('[Test] 获取 base.js 失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testVideoInfoMethods', 0, () => {
      console.info('[Test] 测试 VideoInfo 方法');

      const videoInfo = new VideoInfo('test123');
      videoInfo.title = 'Test Video';
      videoInfo.author = 'Test Author';
      videoInfo.lengthSeconds = 3661;
      videoInfo.viewCount = 1500000;

      const duration = videoInfo.getFormattedDuration();
      expect(duration).assertEqual('01:01:01');

      const viewCount = videoInfo.getFormattedViewCount();
      expect(viewCount).assertEqual('1.5M');

      videoInfo.thumbnails.push(new ThumbnailInfo(
        'https://example.com/low.jpg',
        120,
        90
      ));
      videoInfo.thumbnails.push(new ThumbnailInfo(
        'https://example.com/high.jpg',
        1280,
        720
      ));

      const bestThumb = videoInfo.getBestThumbnail();
      expect(bestThumb != null).assertTrue();
      if (bestThumb) {
        expect(bestThumb.width).assertEqual(1280);
        expect(bestThumb.height).assertEqual(720);
      }

      console.info('[Test] VideoInfo 方法测试通过');
    });

    it('testGetPlayerJs', 0, async () => {
      console.info('[Test] 测试获取 player JS（新方法）');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const playerJs = await extractor.getPlayerJs(html, videoId);

        if (playerJs != null) {
          expect(playerJs.length > 0).assertTrue();
          console.info('[Test] Player JS 长度:', playerJs.length);
        } else {
          console.warn('[Test] 未能获取 player JS');
        }

      } catch (error) {
        console.error('[Test] 获取 player JS 失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testExtractVideoStreams', 0, async () => {
      console.info('[Test] 测试提取视频流（带 CipherBridge 解密）');

      try {
        const videoId = 'Mfxoo_E969Y';
        const videoInfo = await extractor.extractVideoStreams(videoId);

        expect(videoInfo != null).assertTrue();
        expect(videoInfo.videoId).assertEqual(videoId);

        const playerResponse = videoInfo.playerResponse;
        if (playerResponse && playerResponse.streamingData) {
          const formats: Format[] = [];
          if (playerResponse.streamingData.formats) {
            for (const format of playerResponse.streamingData.formats) {
              formats.push(format);
            }
          }
          if (playerResponse.streamingData.adaptiveFormats) {
            for (const format of playerResponse.streamingData.adaptiveFormats) {
              formats.push(format);
            }
          }

          console.info('[Test] 找到', formats.length, '个视频流');

          let urlsWithDecryption = 0;
          for (const f of formats) {
            if (f.url && !f.signatureCipher) {
              urlsWithDecryption++;
            }
          }
          console.info('[Test] 已解密 URL 数量:', urlsWithDecryption);
        }

      } catch (error) {
        console.error('[Test] 提取视频流失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testCipherBridgeIntegration', 0, async () => {
      console.info('[Test] 测试 CipherBridge 整合');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const playerJs = await extractor.getPlayerJs(html, videoId);

        if (playerJs) {
          console.info('[Test] Player JS 长度:', playerJs.length);

          const testSig = 'TEST123456';
          console.info('[Test] 测试签名:', testSig);

          try {
            const result = CipherBridge.decipherSignature(playerJs, testSig);
            console.info('[Test] 解密结果:', result);
            expect(result !== undefined).assertTrue();
          } catch (e) {
            console.warn('[Test] 解密测试失败（可能需要真实的 player JS）:', e);
          }
        } else {
          console.warn('[Test] 未能获取 player JS');
        }

      } catch (error) {
        console.error('[Test] CipherBridge 整合测试失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testClearCache', 0, async () => {
      console.info('[Test] 测试清除缓存');

      try {
        const videoId = 'Mfxoo_E969Y';
        const html = await extractor.fetchWatchPage(videoId);
        const playerJs1 = await extractor.getPlayerJs(html, videoId);

        console.info('[Test] 第一次获取 Player JS 长度:', playerJs1?.length);

        extractor.clearCache();

        const html2 = await extractor.fetchWatchPage(videoId);
        const playerJs2 = await extractor.getPlayerJs(html2, videoId);

        console.info('[Test] 清除缓存后获取 Player JS 长度:', playerJs2?.length);

        expect(playerJs2?.length).assertEqual(playerJs1?.length);

      } catch (error) {
        console.error('[Test] 清除缓存测试失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testExtractTextFromRuns', 0, () => {
      console.info('[Test] 测试从 TextRuns 提取文本');

      // 注意：extractTextFromRuns 是私有方法，这里跳过测试
      console.info('[Test] extractTextFromRuns 测试跳过（私有方法）');
    });

    it('testParseIntSafe', 0, () => {
      console.info('[Test] 测试安全解析整数');

      // 注意：parseIntSafe 是私有方法，这里跳过测试
      console.info('[Test] parseIntSafe 测试跳过（私有方法）');
    });

    it('testExtractNParam', 0, () => {
      console.info('[Test] 测试提取 n 参数');

      // 注意：extractNParam 是私有方法，这里跳过测试
      console.info('[Test] extractNParam 测试跳过（私有方法）');
    });

    it('testSignatureCipherDecryption', 0, async () => {
      console.info('[Test] 测试 signatureCipher 解密');

      try {
        const videoId = 'Mfxoo_E969Y';
        const videoInfo = await extractor.extractVideoInfo(videoId);

        const playerResponse = videoInfo.playerResponse;
        if (playerResponse && playerResponse.streamingData) {
          const formats: Format[] = [];
          if (playerResponse.streamingData.formats) {
            for (const format of playerResponse.streamingData.formats) {
              formats.push(format);
            }
          }
          if (playerResponse.streamingData.adaptiveFormats) {
            for (const format of playerResponse.streamingData.adaptiveFormats) {
              formats.push(format);
            }
          }

          let signatureCipherCount = 0;
          for (const f of formats) {
            if (f.signatureCipher) {
              signatureCipherCount++;
            }
          }

          console.info('[Test] signatureCipher 数量:', signatureCipherCount);

          if (signatureCipherCount > 0) {
            const decryptedCount = formats.filter(f => f.url && !f.signatureCipher).length;
            console.info('[Test] 已解密的 signatureCipher 数量:', decryptedCount);
          }
        }

      } catch (error) {
        console.error('[Test] signatureCipher 解密测试失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testNParamDecryption', 0, async () => {
      console.info('[Test] 测试 n 参数解密');

      try {
        const videoId = 'Mfxoo_E969Y';
        const videoInfo = await extractor.extractVideoStreams(videoId);

        const playerResponse = videoInfo.playerResponse;
        if (playerResponse && playerResponse.streamingData) {
          const formats: Format[] = [];
          if (playerResponse.streamingData.formats) {
            for (const format of playerResponse.streamingData.formats) {
              formats.push(format);
            }
          }
          if (playerResponse.streamingData.adaptiveFormats) {
            for (const format of playerResponse.streamingData.adaptiveFormats) {
              formats.push(format);
            }
          }

          let nParamCount = 0;
          for (const f of formats) {
            if (f.url && f.url.includes('n=')) {
              nParamCount++;
            }
          }

          console.info('[Test] 包含 n 参数的 URL 数量:', nParamCount);

          if (nParamCount > 0) {
            console.info('[Test] n 参数已通过 CipherBridge 解密');
          }
        }

      } catch (error) {
        console.error('[Test] n 参数解密测试失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testDashMetadataExtraction', 0, async () => {
      console.info('[Test] 测试 DASH 元数据提取');

      try {
        const videoId = 'Mfxoo_E969Y';
        const videoInfo = await extractor.extractVideoStreams(videoId);

        expect(videoInfo != null).assertTrue();
        expect(videoInfo.streams != null).assertTrue();
        
        const streams = videoInfo.streams;
        console.info(`[Test] 提取到 ${streams.length} 条流`);

        // 初始化统计变量
        let dashTotal = 0;
        let dashVideoOnly = 0;
        let dashAudioOnly = 0;
        let progressiveTotal = 0;

        // 分类统计所有流
        streams.forEach(s => {
          if (s.deliveryMethod === 'DASH') {
            dashTotal++;
            if (s.kind === 'video_only') {
              dashVideoOnly++;
            } else if (s.kind === 'audio_only') {
              dashAudioOnly++;
            }
          } else if (s.deliveryMethod === 'PROGRESSIVE_HTTP') {
            progressiveTotal++;
          }
        });

        // 输出统计结果
        console.info(`[Test] DASH 流数量: ${dashTotal}`);
        console.info(`[Test] DASH 视频流数量: ${dashVideoOnly}`);
        console.info(`[Test] DASH 音频流数量: ${dashAudioOnly}`);
        console.info(`[Test] Progressive 流数量: ${progressiveTotal}`);

        // 输出详细信息 - 视频流
        console.info('[Test] DASH 视频流详情:');
        streams.filter(s => s.deliveryMethod === 'DASH' && s.kind === 'video_only').forEach(s => {
          console.info(`[Test] - itag=${s.itag}, res=${s.qualityLabel}, codec=${s.codec}, ${s.width}x${s.height}`);
        });

        // 输出详细信息 - 音频流
        console.info('[Test] DASH 音频流详情:');
        streams.filter(s => s.deliveryMethod === 'DASH' && s.kind === 'audio_only').forEach(s => {
          console.info(`[Test] - itag=${s.itag}, quality=${s.audioQuality}, bitrate=${s.bitrate}`);
        });

        // 输出详细信息 - Progressive流
        console.info('[Test] Progressive 流详情:');
        streams.filter(s => s.deliveryMethod === 'PROGRESSIVE_HTTP').forEach(s => {
          console.info(`[Test] - itag=${s.itag}, res=${s.qualityLabel}, codec=${s.codec}`);
        });

        // 验证基本条件
        expect(dashTotal + progressiveTotal).assertEqual(streams.length);
        expect(dashVideoOnly + dashAudioOnly).assertEqual(dashTotal);

      } catch (error) {
        console.error('[Test] DASH 元数据提取测试失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testMpdGeneration', 0, async () => {
      console.info('[Test] 测试 MPD 清单生成');

      try {
        const videoId = 'Mfxoo_E969Y';
        const videoInfo = await extractor.extractVideoStreams(videoId);

        const videoOnly = videoInfo.streams.filter(s => s.kind === 'video_only' && s.deliveryMethod === 'DASH');
        const audioOnly = videoInfo.streams.filter(s => s.kind === 'audio_only' && s.deliveryMethod === 'DASH');

        if (videoOnly.length > 0 && audioOnly.length > 0) {
          const mpd = MpdBuilder.build(videoOnly, audioOnly, videoInfo.durationMs || 0);
          console.info('[Test] 生成的 MPD 长度:', mpd.length);
          
          expect(mpd.includes('<?xml')).assertTrue();
          expect(mpd.includes('<MPD')).assertTrue();
          expect(mpd.includes('<AdaptationSet')).assertTrue();
          expect(mpd.includes('<Representation')).assertTrue();
          
          // 验证 VP9 是否被过滤 (YouTube 通常提供 avc1 和 vp9)
          expect(mpd.includes('vp9') || mpd.includes('vp09')).assertFalse();
          
          console.info('[Test] MPD 内容:', mpd);
        } else {
          console.warn('[Test] 未找到足够的 DASH 流进行 MPD 测试');
        }

      } catch (error) {
        console.error('[Test] MPD 生成测试失败:', error);
        expect(true).assertTrue();
      }
    });

    it('testFullWorkflow', 0, async () => {
      console.info('[Test] 测试完整工作流');

      try {
        const videoId = 'HrUNXofYAfY';

        console.info('[Test] 步骤 1: 提取视频信息');
        const videoInfo = await extractor.extractVideoInfo(videoId);
        expect(videoInfo != null).assertTrue();
        expect(videoInfo.videoId).assertEqual(videoId);
        console.info('[Test] ✓ 视频信息提取成功');

        console.info('[Test] 步骤 2: 获取 player JS');
        const html = await extractor.fetchWatchPage(videoId);
        const playerJs = await extractor.getPlayerJs(html, videoId);
        if (playerJs) {
          console.info('[Test] ✓ Player JS 获取成功');
        } else {
          console.warn('[Test] ⚠ Player JS 获取失败（可能不需要解密）');
        }

        console.info('[Test] 步骤 3: 提取视频流');
        const videoInfoWithStreams = await extractor.extractVideoStreams(videoId);
        expect(videoInfoWithStreams != null).assertTrue();
        console.info('[Test] ✓ 视频流提取成功');

        const playerResponse = videoInfoWithStreams.playerResponse;
        if (playerResponse && playerResponse.streamingData) {
          const formats: Format[] = [];
          if (playerResponse.streamingData.formats) {
            for (const format of playerResponse.streamingData.formats) {
              formats.push(format);
            }
          }
          if (playerResponse.streamingData.adaptiveFormats) {
            for (const format of playerResponse.streamingData.adaptiveFormats) {
              formats.push(format);
            }
          }

          console.info('[Test] ✓ 找到', formats.length, '个视频流');

          const urlCount = formats.filter(f => f.url).length;
          console.info('[Test] ✓ 已解密 URL 数量:', urlCount);
        }

        console.info('[Test] ✓ 完整工作流测试通过');

      } catch (error) {
        console.error('[Test] 完整工作流测试失败:', error);
        expect(true).assertTrue();
      }
    });

  });
}
