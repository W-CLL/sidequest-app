// 本地开发用：同源托管 Flutter Web 构建 + 反向代理 /api 到本地 API 服务。
//
// 为什么需要它：网页版依赖 Cookie 会话与同源请求（与线上部署一致），
// 如果让页面和 API 跑在不同端口，Cookie / Origin 行为就和线上不一致。
//
// 用法：
//   1) 先启动 API：  node server/server.mjs
//   2) 再启动本脚本：node scripts/serve-web.mjs
//      （API 端口不是 8787 时用 API_PORT=xxxx 覆盖；页面端口用 PORT=xxxx 覆盖）
//   3) 浏览器打开 http://127.0.0.1:8080
//
// 注意：本地 API 需要把页面源加入允许列表，例如：
//   ALLOWED_ORIGINS=http://127.0.0.1:8080 node server/server.mjs
import { createServer, request as httpRequest } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';

const root = resolve(process.argv[2] ?? 'build/web');
const port = Number(process.env.PORT ?? 8080);
const apiPort = Number(process.env.API_PORT ?? 8787);
const host = '127.0.0.1';

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

const apiPrefixes = ['/api/', '/download', '/privacy', '/terms', '/app-legal'];

function proxy(request, response) {
  const upstream = httpRequest(
    { host, port: apiPort, method: request.method, path: request.url, headers: { ...request.headers, host: `${host}:${apiPort}` } },
    (reply) => {
      response.writeHead(reply.statusCode ?? 502, reply.headers);
      reply.pipe(response);
    },
  );
  upstream.on('error', () => {
    response.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ error: '本地 API 未启动（先运行 node server/server.mjs）' }));
  });
  request.pipe(upstream);
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, `http://${host}`);
  if (apiPrefixes.some((prefix) => url.pathname === prefix.replace(/\/$/, '') || url.pathname.startsWith(prefix))) {
    proxy(request, response);
    return;
  }
  let filePath = normalize(join(root, decodeURIComponent(url.pathname)));
  if (filePath !== root && !filePath.startsWith(root + sep)) {
    response.writeHead(403); response.end(); return;
  }
  try {
    const info = await stat(filePath);
    if (info.isDirectory()) filePath = join(filePath, 'index.html');
  } catch {
    // 单页应用回退：未命中的路径交给 index.html 路由（与线上 nginx 的 try_files 一致）。
    filePath = join(root, 'index.html');
  }
  try {
    const body = await readFile(filePath);
    response.writeHead(200, {
      'Content-Type': types[extname(filePath).toLowerCase()] ?? 'application/octet-stream',
      // 开发期不缓存，避免旧构建干扰。
      'Cache-Control': 'no-store',
    });
    response.end(body);
  } catch {
    response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('未找到构建产物；先运行 flutter build web --release');
  }
});

server.listen(port, host, () => {
  console.log(`web dev server: http://${host}:${port} (root=${root}, /api → http://${host}:${apiPort})`);
  console.log('提示：API 需要以 ALLOWED_ORIGINS=http://' + host + ':' + port + ' 启动。');
});
