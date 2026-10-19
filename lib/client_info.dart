/// 客户端标识：随请求头 `X-Sidequest-Client` 上报，后台「登录会话」按此显示登录来源。
///
/// - 形如 `platform/版本`，仅在登录/注册时被服务端记录一次；
/// - 不做设备指纹、不记录行为轨迹；
/// - [clientAppVersion] 与 pubspec.yaml 的 `version` 保持一致（发版时同步更新）。
const clientAppVersion = '0.2.1+4';
const clientTagAndroid = 'android/$clientAppVersion';
const clientTagWeb = 'web/$clientAppVersion';
