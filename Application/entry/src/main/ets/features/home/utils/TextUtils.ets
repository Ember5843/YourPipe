export function getTextFromRuns(source: Object | undefined): string {
  if (!source) return "";
  const anySource = source as Record<string, Object>;
  const simpleText = anySource["simpleText"] as string;
  if (simpleText) return simpleText;
  const runs = anySource["runs"] as Array<Record<string, Object>>;
  if (!runs || runs.length === 0) return "";
  return runs.map((run) => (run["text"] as string) || "").join("");
}

export function decodeHtmlEntities(input: string): string {
  let text = input;
  const namedMap: Record<string, string> = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'"
  };
  Object.keys(namedMap).forEach((key) => {
    text = text.split(key).join(namedMap[key]);
  });
  text = text.replace(/&#x([0-9a-fA-F]+);/g, (_: string, hex: string) => {
    const code = parseInt(hex, 16);
    return Number.isFinite(code) ? String.fromCodePoint(code) : '';
  });
  text = text.replace(/&#(\d+);/g, (_: string, num: string) => {
    const code = parseInt(num, 10);
    return Number.isFinite(code) ? String.fromCodePoint(code) : '';
  });
  return text;
}
