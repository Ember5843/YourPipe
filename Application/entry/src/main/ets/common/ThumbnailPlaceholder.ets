export class ThumbnailPlaceholder {
  private static readonly PALETTE: string[] = [
    '#D0D3D8',
    '#C7CCD2',
    '#D6CFC8',
    '#C9D2C8',
    '#D3C9CF',
    '#C6D1D9'
  ];

  private constructor() {
  }

  public static pickColor(seed: string, fallbackIndex: number): string {
    const key = seed && seed.length > 0 ? seed : `${fallbackIndex}`;
    const hash = ThumbnailPlaceholder.hash(key);
    const index = Math.abs(hash) % ThumbnailPlaceholder.PALETTE.length;
    return ThumbnailPlaceholder.PALETTE[index];
  }

  private static hash(text: string): number {
    let hash = 0;
    for (let i = 0; i < text.length; i++) {
      hash = ((hash << 5) - hash) + text.charCodeAt(i);
      hash |= 0;
    }
    return hash;
  }
}
