import extractTest from './extractorTest.test';
import localUnitTest from './LocalUnit.test';
import umpStreamTest from './UmpStream.test';

export default function testsuite() {
  localUnitTest();
  extractTest();
  umpStreamTest();
}