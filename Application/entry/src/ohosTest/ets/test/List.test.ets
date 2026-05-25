import abilityTest from "./Ability.test";
import cipherTest from "./Cipher.test";
import CipherBridgeTest from "./CipherBridge.test";
import youTubeExtractorTest from "./YouTubeExtractor.test";
//import youTubeExtractorAdditionalTest from "./YouTubeExtractorAdditional.test";
import YouTubeHttpClientTest from "./YouTubeHttpClient.test";
import pipLifecycleTest from "./PipLifecycle.test";


export default function testsuite() {
  abilityTest();
  YouTubeHttpClientTest()
  youTubeExtractorTest()
  CipherBridgeTest()
  cipherTest()
  pipLifecycleTest()
  //youTubeExtractorAdditionalTest()
}