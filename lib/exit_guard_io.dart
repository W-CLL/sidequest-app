/// 安卓/桌面端没有“关闭页面”的概念：草稿保护为空实现（进程内已有自己的保存节奏）。
void attachUnsavedDraftGuard(bool Function() hasUnsaved) {}
