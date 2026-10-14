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
// 4) 没有 WebGL 时改走 CPU 绘制。虚拟机、以及部分「添加到桌面」的独立窗口
//    拿不到显卡，引擎默认死等 WebGL，结果就是白屏。
function removeBootSplash() {
  var el = document.getElementById('boot-splash');
  if (!el) return;
  el.classList.add('boot-splash-hide');
  setTimeout(function () { el.remove(); }, 400);
}
window.addEventListener('flutter-first-frame', removeBootSplash);
setTimeout(removeBootSplash, 30000);

function hasWebGL() {
  try {
    var canvas = document.createElement("canvas");
    return !!(canvas.getContext("webgl2") || canvas.getContext("webgl") || canvas.getContext("experimental-webgl"));
  } catch (e) {
    return false;
  }
}

_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    var config = {
      fontFallbackBaseUrl: "https://zx.desktoppet.online/app/webfonts/s/",
    };
    if (!hasWebGL()) config.canvasKitForceCpuOnly = true;
    const appRunner = await engineInitializer.initializeEngine(config);
    await appRunner.runApp();
  },
});
