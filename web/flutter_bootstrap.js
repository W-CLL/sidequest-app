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
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      fontFallbackBaseUrl: "https://zx.desktoppet.online/app/webfonts/s/",
    });
    await appRunner.runApp();
  },
});
