import { Localization, ContentCountry, fetchSearchSuggestions } from 'youtube_core';
import { decodeHtmlEntities } from './utils/TextUtils';

export class SearchSuggestionService {
  private localization: Localization;
  private contentCountry: ContentCountry;

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  async fetchSuggestions(query: string): Promise<Array<string>> {
    if (!query || query.trim().length === 0) {
      return [];
    }
    const response = await fetchSearchSuggestions(this.localization, this.contentCountry, query);
    return SearchSuggestionService.parseSuggestionResponse(response as Object);
  }

  private static parseSuggestionResponse(response: Object): Array<string> {
    if (!Array.isArray(response)) {
      return [];
    }
    if (response.length < 2) {
      return [];
    }
    const rawList = response[1] as Object;
    if (!Array.isArray(rawList)) {
      return [];
    }
    const results: Array<string> = [];
    const items = rawList as Array<Object>;
    items.forEach((entry) => {
      if (typeof entry === 'string') {
        if (entry.length > 0) {
          results.push(decodeHtmlEntities(entry));
        }
        return;
      }
      if (Array.isArray(entry)) {
        const nested = entry as Array<Object>;
        const first = nested.length > 0 ? nested[0] : '';
        if (typeof first === 'string' && first.length > 0) {
          results.push(decodeHtmlEntities(first));
        }
      }
    });
    return results;
  }
}
