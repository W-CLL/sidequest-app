/// 网页版没有系统级后台任务（iOS Web 不支持 Background Sync）：保持空实现。
///
/// 网页版是在线优先：打开页面即拉取最新状态，不需要、也无法注册后台任务。
Future<void> initializeBackgroundSync() async {}
