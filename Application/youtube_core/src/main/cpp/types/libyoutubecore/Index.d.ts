export const initCipherEnv: () => number;
export const destroyCipherEnv: () => void;
export const executeCipher: (jsCode: string, functionName: string, param: string) => string;
export const batchExecuteCipher: (jsCode: string, callsJson: string) => string;
