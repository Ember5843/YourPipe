import { AppLog } from './AppLog';

const logger = AppLog.getInstance('ThemeManager');

export interface ColorPresetItem {
  id: string;
  displayName: string;
  primary: string;
  primaryDeep: string;
}

export const COLOR_PRESETS: ColorPresetItem[] = [
  { id: 'default', displayName: 'Red',      primary: '#E53935', primaryDeep: '#B71C1C' },
  { id: 'orange',  displayName: 'Orange',   primary: '#F1680D', primaryDeep: '#D15C00' },
  { id: 'pink',    displayName: 'Pink',     primary: '#EC4899', primaryDeep: '#BE185D' },
  { id: 'purple',  displayName: 'Purple',   primary: '#8B5CF6', primaryDeep: '#6D28D9' },
  { id: 'blue',    displayName: 'Blue',     primary: '#2563EB', primaryDeep: '#1E40AF' },
  { id: 'cyan',    displayName: 'Cyan',     primary: '#0891B2', primaryDeep: '#0E7490' },
  { id: 'green',   displayName: 'Green',    primary: '#16A34A', primaryDeep: '#15803D' },
  { id: 'amber',   displayName: 'Amber',    primary: '#D97706', primaryDeep: '#B45309' },
  { id: 'gray',    displayName: 'Gray',     primary: '#475569', primaryDeep: '#334155' }
];

const APP_STORAGE_PRIMARY = 'themePrimaryColor';
const APP_STORAGE_PRIMARY_DEEP = 'themePrimaryDeepColor';
const APP_STORAGE_PRESET_ID = 'themePresetId';

export class ThemeManager {
  static getPreset(id: string): ColorPresetItem {
    const found = COLOR_PRESETS.find(p => p.id === id);
    return found ?? COLOR_PRESETS[0];
  }

  static apply(id: string): void {
    const preset = ThemeManager.getPreset(id);
    AppStorage.setOrCreate(APP_STORAGE_PRIMARY, preset.primary);
    AppStorage.setOrCreate(APP_STORAGE_PRIMARY_DEEP, preset.primaryDeep);
    AppStorage.setOrCreate(APP_STORAGE_PRESET_ID, preset.id);
    logger.info(`Theme preset applied: ${preset.id} -> ${preset.primary}`);
  }

  static initFromConfig(colorPreset: string): void {
    ThemeManager.apply(colorPreset);
  }

  static currentPrimary(): string {
    return AppStorage.get<string>(APP_STORAGE_PRIMARY) ?? COLOR_PRESETS[0].primary;
  }
}
