export class SabrProtocolException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SabrProtocolException';
  }
}

export class SabrRecoverableException extends SabrProtocolException {
  constructor(message: string) {
    super(message);
    this.name = 'SabrRecoverableException';
  }
}
