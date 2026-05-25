import { ContentCountry } from 'youtube_core';
import { Localization } from 'youtube_core';

export class LocaleBundle {
  localization: Localization;
  contentCountry: ContentCountry;

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }
}
