{{flutter_js}}
{{flutter_build_config}}

// 支线 Web 客户端 · 自定义引导脚本
//
// 为什么不用默认的 flutter_bootstrap.js：
// 1) 图形引擎（CanvasKit）与回退字体默认从 Google CDN（gstatic.com）加载，
//    国内网络不可达会导致白屏 / 中文缺字——构建已用 --no-web-resources-cdn
//    把 CanvasKit 本地化，这里再把「缺字回退字体」也指到本服务器的镜像目录
//    （/app/webfonts/s/，与 fonts.gstatic.com/s/ 同构，由 nginx 托管）。
// 2) 不带 serviceWorkerSettings：该版本 Flutter 的服务工作线程已在弃用序列，
//    且网页版本就按「在线优先、不做本地缓存」的产品定位。
// 3) 首帧渲染后移除 index.html 中的启动画面（白屏替代），并设 30 秒兜底。
// 4) 桌面 Safari、以及「添加到桌面」的独立窗口，不走 WebGL。
//    虚拟机里 WebGL 经常能创建上下文、但画面合成不出来；引擎中途再退回 CPU 仍是白屏。
//    必须在初始化前就指定 CPU。手机和普通浏览器标签页仍用 WebGL。
function webglPaints() {
  try {
    var canvas = document.createElement("canvas");
    canvas.width = 8;
    canvas.height = 8;
    var gl = canvas.getContext("webgl2") || canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
    if (!gl || !gl.drawingBufferWidth) return false;
    gl.clearColor(1, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    var px = new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    return px[0] > 200;
  } catch (e) {
    return false;
  }
}

function preferCpu() {
  if (!webglPaints()) return true;
  var ua = navigator.userAgent;
  var mobile = /iPhone|iPad|iPod|Android/i.test(ua);
  if (mobile) return false;
  var safari = /Safari\//.test(ua) && !/Chrome|Chromium|Edg\/|CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
  var standalone = window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true;
  return safari || standalone;
}
function removeBootSplash() {
  var el = document.getElementById('boot-splash');
  if (!el) return;
  el.classList.add('boot-splash-hide');
  setTimeout(function () { el.remove(); }, 400);
}
window.addEventListener('flutter-first-frame', removeBootSplash);
setTimeout(removeBootSplash, 30000);

_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    var config = {
      fontFallbackBaseUrl: "https://zx.desktoppet.online/app/webfonts/s/",
    };
    if (preferCpu()) config.canvasKitForceCpuOnly = true;
    const appRunner = await engineInitializer.initializeEngine(config);
    await appRunner.runApp();
  },
});
