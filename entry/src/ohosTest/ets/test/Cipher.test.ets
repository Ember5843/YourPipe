import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { Cipher, CipherOperation, CipherError } from 'youtube_core';

export default function cipherTest() {
  describe('CipherTest', () => {

    it('testDecipherReverse', 0, () => {
      console.info('[Test] 测试 decipher reverse 操作');

      const operations: CipherOperation[] = [
        { type: 'reverse' }
      ];
      const cipher = new Cipher(operations, 'test');

      const input = 'abcdef';
      const result = cipher.decipher(input);

      expect(result).assertEqual('fedcba');
      console.info('[Test] reverse 操作测试通过');
    });

    it('testDecipherSlice', 0, () => {
      console.info('[Test] 测试 decipher slice 操作');

      const operations: CipherOperation[] = [
        { type: 'slice', value: 2 }
      ];
      const cipher = new Cipher(operations, 'test');

      const input = 'abcdef';
      const result = cipher.decipher(input);

      // slice(2) 应该保留从索引 2 开始的部分: cdef
      expect(result).assertEqual('cdef');
      console.info('[Test] slice 操作测试通过');
    });

    it('testDecipherSwap', 0, () => {
      console.info('[Test] 测试 decipher swap 操作');

      const operations: CipherOperation[] = [
        { type: 'swap', value: 3 }
      ];
      const cipher = new Cipher(operations, 'test');

      const input = 'abcdef';
      const result = cipher.decipher(input);

      // swap(3) 应该交换索引 0 和 3 的字符: dbc aef -> dbcaef
      expect(result).assertEqual('dbcaef');
      console.info('[Test] swap 操作测试通过');
    });

    it('testDecipherCombined', 0, () => {
      console.info('[Test] 测试 decipher 组合操作');

      const operations: CipherOperation[] = [
        { type: 'reverse' },
        { type: 'slice', value: 2 },
        { type: 'swap', value: 1 }
      ];
      const cipher = new Cipher(operations, 'test');

      const input = 'abcdef';
      const result = cipher.decipher(input);

      // reverse: fedcba
      // slice(2): dcba
      // swap(1): cdba
      expect(result).assertEqual('cdba');
      console.info('[Test] 组合操作测试通过');
    });

    it('testGetOperations', 0, () => {
      console.info('[Test] 测试 getOperations');

      const operations: CipherOperation[] = [
        { type: 'reverse' },
        { type: 'slice', value: 3 }
      ];
      const cipher = new Cipher(operations, 'test');

      const retrieved = cipher.getOperations();
      expect(retrieved.length).assertEqual(2);
      expect(retrieved[0].type).assertEqual('reverse');
      expect(retrieved[1].type).assertEqual('slice');
      expect(retrieved[1].value).assertEqual(3);

      console.info('[Test] getOperations 测试通过');
    });

    it('testGetName', 0, () => {
      console.info('[Test] 测试 getName');

      const cipher = new Cipher([], 'testCipher');
      expect(cipher.getName()).assertEqual('testCipher');

      const cipherNoName = new Cipher([]);
      expect(cipherNoName.getName()).assertNull();

      console.info('[Test] getName 测试通过');
    });

    it('testCipherError', 0, () => {
      console.info('[Test] 测试 CipherError');

      try {
        throw new CipherError('Test error');
      } catch (e) {
        expect(e instanceof CipherError).assertTrue();
        expect((e as CipherError).message).assertEqual('Test error');
        expect((e as CipherError).name).assertEqual('CipherError');
      }

      console.info('[Test] CipherError 测试通过');
    });

    it('testDecipherWithRealSignature', 0, () => {
      console.info('[Test] 测试真实签名解密');

      // 模拟 YouTube 签名解密流程
      // 假设原始签名是 "abcdefghij"
      // 操作序列: reverse -> slice(3) -> swap(2)
      // reverse: jihgfedcba
      // slice(3): gfedcba
      // swap(2): efgdcba

      const operations: CipherOperation[] = [
        { type: 'reverse' },
        { type: 'slice', value: 3 },
        { type: 'swap', value: 2 }
      ];
      const cipher = new Cipher(operations, 'realTest');

      const input = 'abcdefghij';
      const result = cipher.decipher(input);

      expect(result).assertEqual('efgdcba');
      console.info('[Test] 真实签名解密测试通过');
    });

    it('testEmptyOperations', 0, () => {
      console.info('[Test] 测试空操作列表');

      const cipher = new Cipher([], 'empty');
      const input = 'test';
      const result = cipher.decipher(input);

      // 空操作应该返回原字符串
      expect(result).assertEqual('test');
      console.info('[Test] 空操作列表测试通过');
    });

    it('testDecipherErrorMissingValue', 0, () => {
      console.info('[Test] 测试 decipher 缺少 value 错误');

      const operations: CipherOperation[] = [
        { type: 'slice' }  // 缺少 value
      ];
      const cipher = new Cipher(operations, 'errorTest');

      try {
        cipher.decipher('test');
        expect(false).assertTrue();  // 应该抛出异常
      } catch (e) {
        expect(e instanceof CipherError).assertTrue();
        console.info('[Test] decipher 错误处理测试通过');
      }
    });

  });
}
