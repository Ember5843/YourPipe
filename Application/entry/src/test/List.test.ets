import extractTest from './extractorTest.test';
import localUnitTest from './LocalUnit.test';

export default function testsuite() {
  localUnitTest();
  extractTest();
}