import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { CipherBridge } from 'youtube_core';

export default function CipherBridgeTest() {
  describe('CipherBridgeTest', () => {

    beforeAll(() => {
      console.info('[Test] Initializing CipherBridge');
      CipherBridge.init();
    });

    afterAll(() => {
      console.info('[Test] Destroying CipherBridge');
      CipherBridge.destroy();
    });

    it('testBasicJsExecution', 0, () => {
      console.info('[Test] Testing basic JS execution');

      const jsCode = `
        function testFunction(input) {
          return "Hello " + input;
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'testFunction', 'World');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('Hello World');
    });

    it('testStringReverse', 0, () => {
      console.info('[Test] Testing string reverse');

      const jsCode = `
        function reverseString(str) {
          return str.split('').reverse().join('');
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'reverseString', 'abcdef');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('fedcba');
    });

    it('testCipherOperations', 0, () => {
      console.info('[Test] Testing cipher operations');

      const jsCode = `
        function decipherSignature(sig) {
          var chars = sig.split('');
          chars.reverse();
          chars = chars.slice(3);
          var temp = chars[0];
          chars[0] = chars[2];
          chars[2] = temp;
          return chars.join('');
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.executeCipher(jsCode, 'decipherSignature', testSig);
      console.info('[Test] Input:', testSig, 'Output:', result);

      expect(result.length).assertEqual(7);
    });

    it('testExtractHelperObjects', 0, () => {
      console.info('[Test] Testing helper objects extraction');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); },
          cd: function(a, b) { a.splice(0, b); },
          ef: function(a, b) { var c = a[0]; a[0] = a[b % a.length]; a[b % a.length] = c; }
        };

        var a = ["r", "s", "w"];

        sigDecode = function(a) {
          a = a.split("");
          Xk.ab(a);
          Xk.cd(a, 2);
          Xk.ef(a, 3);
          return a.join("");
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Result:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    });

    it('testExtractNestedHelperObjects', 0, () => {
      console.info('[Test] Testing nested helper objects extraction');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { 
            a.reverse(); 
          },
          cd: function(a, b) { 
            var temp = a;
            a = [];
            for (var i = b; i < temp.length; i++) {
              a.push(temp[i]);
            }
          },
          'ef-gh': function(a, b) { 
            if (a.length > 0) {
              var c = a[0];
              a[0] = a[b % a.length];
              a[b % a.length] = c;
            }
          }
        };

        sigDecode = function(a) {
          a = a.split("");
          Xk["ef-gh"](a, 4);
          Xk.ab(a);
          Xk.cd(a, 1);
          return a.join("");
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Result:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    });

    it('testExtractHelperFunctions', 0, () => {
      console.info('[Test] Testing helper functions extraction');

      const mockPlayerJs = `
        function ab(a) {
          a.reverse();
        }

        function cd(a, b) {
          a.splice(0, b);
        }

        function ef(a, b) {
          var c = a[0];
          a[0] = a[b % a.length];
          a[b % a.length] = c;
        }

        sigDecode = function(a) {
          a = a.split("");
          ab(a);
          cd(a, 2);
          ef(a, 3);
          return a.join("");
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Result:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    });

    it('testExtractArrayLiterals', 0, () => {
      console.info('[Test] Testing array literals extraction');

      const mockPlayerJs = `
        var a = ["r", "s", "w"];

        function ab(a) {
          a.reverse();
        }

        function cd(a, b) {
          a.splice(0, b);
        }

        function ef(a, b) {
          var c = a[0];
          a[0] = a[b % a.length];
          a[b % a.length] = c;
        }

        sigDecode = function(a) {
          a = a.split("");
          var b = a[0];
          var c = a[0];
          a[0] = a[b % a.length];
          a[b % a.length] = c;
          ab(a);
          a = a[c];
          a = a[b];
          return a.join("");
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Result:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    });

    it('testComplexPlayerJs', 0, () => {
      console.info('[Test] Testing complex player JS with mixed dependencies');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); },
          cd: function(a, b) { a.splice(0, b); },
          ef: function(a, b) { var c = a[0]; a[0] = a[b % a.length]; a[b % a.length] = c; }
        };

        var a = ["r", "s", "w"];

        function gh(a, b) {
          var c = a[0];
          a[0] = a[b % a.length];
          a[b % a.length] = c;
        }

        sigDecode = function(a) {
          a = a.split("");
          Xk.ab(a);
          Xk.cd(a, 2);
          gh(a, 3);
          return a.join("");
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Result:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    });

    it('testExtractEnclosedBlockBraces', 0, () => {
      console.info('[Test] Testing extractEnclosedBlock with braces');

      const jsCode = `
        function test() {
          var obj = {
            nested: {
              value: "test"
            }
          };
          return obj.nested.value;
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'test', '');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('test');
    });

    it('testExtractEnclosedBlockBrackets', 0, () => {
      console.info('[Test] Testing extractEnclosedBlock with brackets');

      const jsCode = `
        function test() {
          var arr = ["a", "b", "c"];
          return arr[1];
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'test', '');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('b');
    });

    it('testExtractEnclosedBlockWithStrings', 0, () => {
      console.info('[Test] Testing extractEnclosedBlock with strings');

      const jsCode = `
        function test() {
          var str = "{not-a-block}";
          var obj = {real: "block"};
          return obj.real;
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'test', '');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('block');
    });

    it('testExtractEnclosedBlockWithComments', 0, () => {
      console.info('[Test] Testing extractEnclosedBlock with comments');

      const jsCode = `
        function test() {
          var obj = {
            // comment with { bracket
            value: "test"
          };
          return obj.value;
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'test', '');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('test');
    });

    it('testExtractEnclosedBlockWithEscapedQuotes', 0, () => {
      console.info('[Test] Testing extractEnclosedBlock with escaped quotes');

      const jsCode = `
        function test() {
          var str = "escaped \\" quote";
          return str;
        }
      `;

      const result = CipherBridge.executeCipher(jsCode, 'test', '');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('escaped " quote');
    });

    it('testFindSignatureFunc', 0, () => {
      console.info('[Test] Testing findSignatureFunc');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); }
        };

        sigDecode = function(a) {
          a = a.split("");
          Xk.ab(a);
          return a.join("");
        }
      `;

      const testSig = 'ABCDEF';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Input:', testSig, 'Output:', result);

      expect(result).assertEqual('FEDCBA');
    });

    it('testFindSignatureFuncWithSplitJoin', 0, () => {
      console.info('[Test] Testing findSignatureFunc with split/join heuristic');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); }
        };

        sigDecode = function(a) {
          var b = a.split("");
          Xk.ab(b);
          return b.join("");
        }
      `;

      const testSig = 'ABCDEF';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Input:', testSig, 'Output:', result);

      expect(result).assertEqual('FEDCBA');
    });

    it('testDecipherSignatureMethod', 0, () => {
      console.info('[Test] Testing decipherSignature method');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); },
          cd: function(a, b) { a.splice(0, b); },
          ef: function(a, b) { var c = a[0]; a[0] = a[b % a.length]; a[b % a.length] = c; }
        };

        var a = ["r", "s", "w"];

        sigDecode = function(a) {
          a = a.split("");
          Xk.ab(a);
          Xk.cd(a, 2);
          Xk.ef(a, 3);
          return a.join("");
        }
      `;

      const testSig = 'ABCDEFGHIJ';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Result:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    });

    it('testMultipleSignatures', 0, () => {
      console.info('[Test] Testing multiple signature decryptions');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); },
          cd: function(a, b) { a.splice(0, b); },
          ef: function(a, b) { var c = a[0]; a[0] = a[b % a.length]; a[b % a.length] = c; }
        };

        var a = ["r", "s", "w"];

        sigDecode = function(a) {
          a = a.split("");
          Xk.ab(a);
          Xk.cd(a, 2);
          Xk.ef(a, 3);
          return a.join("");
        }
      `;

      const signatures = ['ABCDEF', '123456', 'TEST123', 'HELLO'];
      const results: string[] = [];

      for (const sig of signatures) {
        const result = CipherBridge.decipherSignature(mockPlayerJs, sig);
        results.push(result);
        console.info('[Test] Input:', sig, 'Output:', result);
      }

      expect(results.length).assertEqual(4);
      for (const result of results) {
        expect(result !== undefined).assertTrue();
        expect(result !== null).assertTrue();
      }
    });

    it('testEmptySignature', 0, () => {
      console.info('[Test] Testing empty signature');

      const mockPlayerJs = `
        sigDecode = function(a) {
          return a;
        }
      `;

      const result = CipherBridge.decipherSignature(mockPlayerJs, '');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('');
    });

    it('testSingleCharSignature', 0, () => {
      console.info('[Test] Testing single character signature');

      const mockPlayerJs = `
        sigDecode = function(a) {
          return a;
        }
      `;

      const result = CipherBridge.decipherSignature(mockPlayerJs, 'A');
      console.info('[Test] Result:', result);

      expect(result).assertEqual('A');
    });

    it('testLongSignature', 0, () => {
      console.info('[Test] Testing long signature');

      const mockPlayerJs = `
        function reverseString(str) {
          return str.split('').reverse().join('');
        }

        sigDecode = function(a) {
          return reverseString(a);
        }
      `;

      const longSig = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      const result = CipherBridge.decipherSignature(mockPlayerJs, longSig);
      console.info('[Test] Input length:', longSig.length, 'Output length:', result.length);

      expect(result.length).assertEqual(longSig.length);
      expect(result).assertEqual('9876543210ZYXWVUTSRQPONMLKJIHGFEDCBA');
    });

    it('testRealWorldPlayerJsPattern', 0, () => {
      console.info('[Test] Testing real-world player JS pattern');

      const mockPlayerJs = `
        var Xk = {
          ab: function(a) { a.reverse(); },
          cd: function(a, b) { a.splice(0, b); },
          ef: function(a, b) { var c = a[0]; a[0] = a[b % a.length]; a[b % a.length] = c; }
        };

        var a = ["r", "s", "w"];

        sigDecode = function(a) {
          a = a.split("");
          Xk.ab(a);
          Xk.cd(a, 2);
          Xk.ef(a, 3);
          return a.join("");
        }
      `;

      const testSig = 'THIS_IS_A_TEST_SIGNATURE_123';
      const result = CipherBridge.decipherSignature(mockPlayerJs, testSig);
      console.info('[Test] Input:', testSig);
      console.info('[Test] Output:', result);

      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
      expect(result.length).assertLess(testSig.length);
    });

  });
}
