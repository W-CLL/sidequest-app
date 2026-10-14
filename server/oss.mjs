// 极简阿里云 OSS 客户端：签名 / 上传 / 探测，只用 node 内置模块（与 server.mjs 的零依赖风格一致）。
//
// 配置来自环境变量（systemd EnvironmentFile 注入）：
//   OSS_REGION / OSS_ENDPOINT / OSS_BUCKET / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET
//   OSS_PREFIX（对象前缀，如 sidequest）/ OSS_URL_EXPIRES（签名有效秒数，默认 900）
//   OSS_DOWNLOAD_DOMAIN（绑定到 bucket 的自定义域名，如 oss-download.desktoppet.online）
//
// 配置不完整时返回 null——下载继续走服务器带宽，绝不让可选加速影响主服务可用性。

import { createHash, createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';

function normalizeExpires(value) {
  const seconds = Number(value ?? 900);
  return Number.isInteger(seconds) && seconds >= 60 && seconds <= 86400 ? seconds : 900;
}

export function resolveOssConfig(env = process.env) {
  const config = {
    region: String(env.OSS_REGION ?? '').trim(),
    endpoint: String(env.OSS_ENDPOINT ?? '').trim().replace(/^https?:\/\//, '').replace(/\/+$/, ''),
    bucket: String(env.OSS_BUCKET ?? '').trim(),
    accessKeyId: String(env.OSS_ACCESS_KEY_ID ?? '').trim(),
    accessKeySecret: String(env.OSS_ACCESS_KEY_SECRET ?? '').trim(),
    prefix: String(env.OSS_PREFIX ?? '').trim().replace(/^\/+|\/+$/g, ''),
    downloadDomain: String(env.OSS_DOWNLOAD_DOMAIN ?? '').trim().replace(/^https?:\/\//, '').replace(/\/+$/, ''),
    urlExpires: normalizeExpires(env.OSS_URL_EXPIRES),
  };
  const required = ['endpoint', 'bucket', 'accessKeyId', 'accessKeySecret'];
  const present = required.filter((key) => config[key]);
  if (present.length === 0) return null;
  if (present.length !== required.length) {
    console.warn('[oss] 配置不完整，已禁用 OSS（需要 OSS_ENDPOINT、OSS_BUCKET、OSS_ACCESS_KEY_ID、OSS_ACCESS_KEY_SECRET）');
    return null;
  }
  return config;
}

const encodeKey = (key) => key.split('/').map((segment) => encodeURIComponent(segment)).join('/');
const encode = (value) => encodeURIComponent(value).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

export class OssClient {
  constructor(config, { fetchImpl = fetch, now = Date.now } = {}) {
    this.config = config;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.signingContext = createHash('sha256').update(JSON.stringify(config)).digest('hex');
  }

  objectKey(fileName) {
    return this.config.prefix ? `${this.config.prefix}/${fileName}` : fileName;
  }

  host() {
    return this.config.downloadDomain
      ? `https://${this.config.downloadDomain}`
      : `https://${this.config.bucket}.${this.config.endpoint}`;
  }

  resource(key) {
    // 实测（对刀 ali-oss SDK）：即使通过自定义域名签名，CanonicalizedResource
    // 也必须是 /{bucket}/{key}——写 /{key} 会被 OSS 判 403。
    return `/${this.config.bucket}/${key}`;
  }

  signedUrl(key, method = 'GET') {
    const expires = Math.floor(this.now() / 1000) + this.config.urlExpires;
    const stringToSign = `${method}\n\n\n${expires}\n${this.resource(key)}`;
    const signature = createHmac('sha1', this.config.accessKeySecret).update(stringToSign).digest('base64');
    return `${this.host()}/${encodeKey(key)}?OSSAccessKeyId=${encode(this.config.accessKeyId)}&Expires=${expires}&Signature=${encode(signature)}`;
  }

  /// 用签名 HEAD 探测对象是否存在且大小正确——同时验证公网域名、TLS 与签名链路。
  async probe(key, { timeoutMs = 6000 } = {}) {
    const response = await this.fetchImpl(this.signedUrl(key, 'HEAD'), { method: 'HEAD', signal: AbortSignal.timeout(timeoutMs) });
    if (response.status !== 200) return { ok: false, size: null };
    return { ok: true, size: Number(response.headers.get('content-length') ?? Number.NaN) };
  }

  async upload(key, filePath, { contentType, fileName } = {}) {
    const body = readFileSync(filePath);
    const contentMd5 = createHash('md5').update(body).digest('base64');
    const date = new Date(this.now()).toUTCString();
    const stringToSign = `PUT\n${contentMd5}\n${contentType}\n${date}\n/${this.config.bucket}/${key}`;
    const signature = createHmac('sha1', this.config.accessKeySecret).update(stringToSign).digest('base64');
    const response = await this.fetchImpl(`https://${this.config.bucket}.${this.config.endpoint}/${encodeKey(key)}`, {
      method: 'PUT',
      headers: {
        Date: date,
        'Content-MD5': contentMd5,
        'Content-Type': contentType,
        'Content-Disposition': `attachment; filename="${fileName ?? key.split('/').pop()}"`,
        'Cache-Control': 'private, no-store',
        Authorization: `OSS ${this.config.accessKeyId}:${signature}`,
      },
      body,
      signal: AbortSignal.timeout(300000),
    });
    if (!response.ok) {
      let detail = '';
      try { detail = (await response.text()).slice(0, 200); } catch { /* 忽略 */ }
      throw new Error(`OSS PUT ${response.status}${detail ? ` ${detail}` : ''}`);
    }
    return { size: body.length };
  }
}
