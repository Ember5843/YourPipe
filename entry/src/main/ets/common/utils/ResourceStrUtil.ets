/**
 * ResourceStr 解析工具：string 直接返回，Resource（如 $r 传入的角标标签）
 * 经 resourceManager 解析成字符串；解析失败返回 ''（非关键展示场景静默降级）。
 */
export function resolveResourceStr(value: ResourceStr): string {
  if (typeof value === 'string') {
    return value;
  }
  try {
    return getContext().resourceManager.getStringSync((value as Resource).id);
  } catch (_e) {
    return '';
  }
}
