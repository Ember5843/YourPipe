import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium'
import { fetchSearchPage, Localization, ContentCountry } from 'youtube_core';
export default function YoutubeSerachExtractorTest() {
  describe('YoutubeSerachExtractorTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {

      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    })
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    })
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    })
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    })
    it('assertEqual', 0, async () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.

      try {
        await fetchSearchPage(new Localization('en', 'US'), new ContentCountry('US'), "婆婆听不懂人话", [], '');
      } catch (err) {
        console.error('fetchSearchPage failed:', JSON.stringify(err));
      }

      let a = 'test'
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertEqual('test')
    })
  })
}
