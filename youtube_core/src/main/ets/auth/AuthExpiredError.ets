/**
 * 登录态静默过期信号：服务器拒绝携带凭据的请求（HTTP 401 或 Innertube
 * error.code=16 / status=UNAUTHENTICATED）时抛出，调用方可据此回落到游客路径并提示重新登录。
 * 不得把 cookie / token 等凭据值写入 message。
 */
export class AuthExpiredError extends Error {
  readonly httpCode: number;

  constructor(message: string, httpCode: number = 0) {
    super(message);
    this.name = 'AuthExpiredError';
    this.httpCode = httpCode;
  }
}

/**
 * 判定一次响应是否属于"登录凭据被拒"：
 * - HTTP 401；
 * - 响应体 error 对象 code===16 或 status==='UNAUTHENTICATED'。
 */
export function isAuthRejectionResponse(
  httpCode: number,
  errorObj: Record<string, Object> | undefined
): boolean {
  if (httpCode === 401) {
    return true;
  }
  if (!errorObj) {
    return false;
  }
  const code = errorObj['code'];
  if (typeof code === 'number' && code === 16) {
    return true;
  }
  const status = errorObj['status'];
  if (typeof status === 'string' && status === 'UNAUTHENTICATED') {
    return true;
  }
  return false;
}
