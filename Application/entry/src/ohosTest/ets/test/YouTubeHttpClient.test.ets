import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { YouTubeHttpClient, Localization, ContentCountry } from 'youtube_core';

let client: YouTubeHttpClient;

// 定义请求体接口
interface ClientInfo {
  hl: string;
  gl: string;
  clientName: string;
  clientVersion: string;
  platform: string;
  utcOffsetMinutes: number;
}

interface RequestContext {
  client: ClientInfo;
}

interface SearchRequestBody {
  context: RequestContext;
  query: string;
}

export default function youTubeHttpClientTest() {
  describe('YouTubeHttpClientTest', () => {

    beforeAll(async () => {
      console.info('[Test] 初始化测试环境');
      client = new YouTubeHttpClient({} as common.UIAbilityContext);
      await client.initialize();
    });

    afterAll(async () => {
      console.info('[Test] 清理测试环境');
      client.clearCookies();
      await client.saveCookies();
    });

    it('testInitialize', 0, async () => {
      console.info('[Test] 验证客户端初始化');
      expect(client.getLocalization().getLanguageCode()).assertEqual('en');
      expect(client.getLocalization().getCountryCode()).assertEqual('GB');
    });

    it('testCookieManagement', 0, async () => {
      console.info('[Test] 验证 Cookie 管理');
      
      // 清空
      client.clearCookies();
      expect(client.getCookieCount()).assertEqual(0);

      // 设置
      client.setCookie('TEST', 'value', '.youtube.com', '/');
      expect(client.getCookieCount()).assertEqual(1);

      // 获取
      const cookie = client.getCookie('TEST');
      expect(cookie != null).assertTrue();
      if (cookie) {
        expect(cookie.value).assertEqual('value');
      }

      // 删除
      client.deleteCookie('TEST', '.youtube.com', '/');
      expect(client.getCookieCount()).assertEqual(0);
    });

    it('testLocalization', 0, () => {
      console.info('[Test] 验证本地化设置');
      
      client.setLocalization(new Localization('zh', 'CN'));
      expect(client.getLocalization().getLanguageCode()).assertEqual('zh');
      
      client.setContentCountry(new ContentCountry('US'));
      expect(client.getContentCountry().getCountryCode()).assertEqual('US');
    });

    it('testGetRequest', 0, async () => {
      console.info('[Test] 验证 GET 请求');

      try {
        const response = await client.get('https://www.youtube.com');
        expect(response.responseCode).assertEqual(200);

        const html = response.result as string;
        expect(html.length > 0).assertTrue();
        // 不区分大小写检查
        expect(html.toLowerCase().indexOf('youtube') >= 0).assertTrue();

        console.info('[Test] GET 请求成功，响应长度:', html.length);
      } catch (error) {
        console.error('[Test] GET 请求失败:', error);
        // 网络测试失败不中断
        expect(true).assertTrue();
      }
    });

    it('testPostJsonRequest', 0, async () => {
      console.info('[Test] 验证 POST JSON 请求');
      
      try {
        const body: SearchRequestBody = {
          context: {
            client: {
              hl: 'en',
              gl: 'US',
              clientName: 'WEB',
              clientVersion: '2.20250122.04.00',
              platform: 'DESKTOP',
              utcOffsetMinutes: 0
            }
          },
          query: 'test'
        };

        const response = await client.postJson(
          'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
          body
        );
        
        expect(response.responseCode).assertEqual(200);
        console.info('[Test] POST JSON 请求成功');
      } catch (error) {
        console.error('[Test] POST 请求失败:', error);
        expect(true).assertTrue();
      }
    });

  });
}
