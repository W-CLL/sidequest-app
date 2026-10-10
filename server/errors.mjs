export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function assert(condition, status, message) {
  if (!condition) throw new HttpError(status, message);
}

export function identifier(value, label = '标识') {
  assert(typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value), 400, `${label}无效`);
  return value;
}

export function fields(body, allowed) {
  assert(Object.keys(body).every((key) => allowed.includes(key)), 400, '请求含未支持的字段');
}

export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
