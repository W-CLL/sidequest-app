import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain.dart';
import 'repository.dart';
import 'pages.dart';
import 'widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    SideQuestApp(
      repository: createRepository(
        apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
      ),
    ),
  );
}

class SideQuestApp extends StatelessWidget {
  const SideQuestApp({super.key, required this.repository});
  final QuestRepository repository;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '支线',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: forest,
        primary: forest,
        surface: paper,
      ),
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: paper,
        indicatorColor: lime,
      ),
    ),
    home: QuestHome(repository: repository),
  );
}

class QuestHome extends StatefulWidget {
  const QuestHome({super.key, required this.repository});
  final QuestRepository repository;
  @override
  State<QuestHome> createState() => _QuestHomeState();
}

class _QuestHomeState extends State<QuestHome> with WidgetsBindingObserver {
  AppSnapshot? state;
  String? error;
  bool busy = false;
  int tab = 0, onboarding = -1;
  String role = '';
  List<String> selectedPreferences = [];
  QuestRepository get repo => widget.repository;
  Quest get quest =>
      questById(state!.activeQuestId ?? state!.recommendedQuestId);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed &&
        state != null &&
        !busy &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      change(repo.load);
    }
  }

  Future<void> boot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var snapshot = await repo.load();
      final savedRole =
          snapshot.profile?.role ?? prefs.getString('ui_role') ?? '';
      final savedPreferences =
          snapshot.profile?.preferences ??
          prefs.getStringList('ui_preferences') ??
          <String>[];
      if (snapshot.profile == null && savedRole.isNotEmpty) {
        snapshot = await repo.savePreferences(savedRole, savedPreferences);
      }
      if (!mounted) return;
      setState(() {
        state = snapshot;
        error = null;
        role = savedRole;
        selectedPreferences = List.of(savedPreferences);
        onboarding = role.isEmpty ? 0 : -1;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<bool> change(Future<AppSnapshot> Function() action) async {
    if (busy) return false;
    setState(() => busy = true);
    try {
      final result = await action();
      if (mounted) {
        setState(() {
          state = result;
          if (result.profile != null) {
            role = result.profile!.role;
            selectedPreferences = List.of(result.profile!.preferences);
          }
        });
      }
      return true;
    } catch (e) {
      toast('$e');
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finishOnboarding() async {
    if (!await change(() => repo.savePreferences(role, selectedPreferences))) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ui_role', role);
      await prefs.setStringList('ui_preferences', selectedPreferences);
      if (mounted) setState(() => onboarding = -1);
    } catch (e) {
      toast('偏好未能保存在设备上，请重试：$e');
    }
  }

  Future<bool> authenticate() async {
    if (state!.profile != null) return true;
    final result = await Navigator.of(context).push<AppSnapshot>(
      MaterialPageRoute(builder: (_) => LoginPage(repository: repo)),
    );
    if (!mounted || result == null) return false;
    setState(() {
      state = result;
      role = result.profile!.role;
      selectedPreferences = List.of(result.profile!.preferences);
    });
    return true;
  }

  Future<void> openQuest() async {
    final selectedId = quest.id;
    final wantsClaim = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QuestDetail(
          quest: quest,
          role: role,
          active: state!.activeQuestId != null,
        ),
      ),
    );
    if (wantsClaim != true || !mounted || !await authenticate() || !mounted) {
      return;
    }
    if (quest.id != selectedId || state!.canRequestNext) {
      toast('已恢复这个账号的任务进度，请从首页继续。');
      return;
    }
    if (state!.activeQuestId == null && !await change(repo.claim)) return;
    if (!mounted) return;
    final completed = await Navigator.of(context).push<AppSnapshot>(
      MaterialPageRoute(
        builder: (_) => RecordPage(
          repository: repo,
          quest: quest,
          initialDraft: state!.draft,
        ),
      ),
    );
    if (!mounted) return;
    await change(repo.load);
    if (completed != null && mounted) {
      setState(() => state = completed);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.spa_outlined, color: forest, size: 48),
          title: const Text('今天多了一点不一样。'),
          content: const Text('这次发现已私密收进探索册。今天就到这里也很好，还想探索可以再领一条。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('回到今日'),
            ),
            TextButton(
              onPressed: () {
                setState(() => tab = 1);
                Navigator.pop(context);
              },
              child: const Text('看看探索册'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> replace() async {
    if (!await authenticate() || !mounted) return;
    if (!await change(repo.load) || !mounted) return;
    if (!state!.replacementAvailable) {
      toast('今天的换题机会已用完。仍可随时停止任务。');
      return;
    }
    if (await confirm(
      context,
      '换一条支线？',
      '每天可以换题一次，换题会清空当前任务的文字草稿。没有惩罚，也不要求完成不合适的任务。',
      '确认换题',
    )) {
      if (await change(repo.replace)) toast('已换一条，今天剩余 0 次。');
    }
  }

  Future<void> stop() async {
    if (await confirm(
      context,
      '先停在这里？',
      '停止不会扣分，也不会增加换题次数。之后可以重新领取这条支线，文字草稿会保留。',
      '停止任务',
    )) {
      await change(repo.stop);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (state == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.spa_outlined, size: 48, color: forest),
                const SizedBox(height: 20),
                if (error == null)
                  const CircularProgressIndicator()
                else ...[
                  Text(error!),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: boot, child: const Text('重试')),
                ],
              ],
            ),
          ),
        ),
      );
    }
    if (onboarding >= 0) return onboardingPage();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: IndexedStack(
              index: tab,
              children: [today(), journal(), profile()],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '探索册',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }

  Widget onboardingPage() {
    final isRole = onboarding == 0;
    return Scaffold(
      appBar: AppBar(
        leading: !isRole
            ? IconButton(
                onPressed: () => setState(() => onboarding = 0),
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: Text(isRole ? '认识一下' : '探索偏好'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              isRole ? '01 / 02' : '02 / 02',
              style: const TextStyle(color: muted),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              key: ValueKey(onboarding),
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 12),
                Text(isRole ? '此刻，你的生活角色？' : '你更喜欢怎样探索？', style: heading),
                const SizedBox(height: 10),
                Text(
                  isRole ? '选一个现在最贴近的身份，之后随时可改。' : '最多选 3 项，也可以跳过。不是性格测试。',
                  style: secondary,
                ),
                const SizedBox(height: 26),
                if (isRole)
                  ...roles.asMap().entries.map((entry) {
                    final option = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => setState(() => role = option.id),
                        child: Container(
                          padding: const EdgeInsets.all(17),
                          decoration: BoxDecoration(
                            color: role == option.id ? pale : Colors.white,
                            border: Border.all(
                              color: role == option.id ? forest : border,
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: [
                              Icon(roleIcons[entry.key], color: forest),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.label,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      option.subtitle,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (role == option.id)
                                const Icon(Icons.check_circle, color: forest),
                            ],
                          ),
                        ),
                      ),
                    );
                  })
                else
                  ...preferences.map((preference) {
                    final checked = selectedPreferences.contains(preference);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: FilterChip(
                        label: SizedBox(
                          width: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              preference,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                        selected: checked,
                        selectedColor: lime,
                        showCheckmark: true,
                        onSelected: (selected) {
                          if (selected && selectedPreferences.length >= 3) {
                            toast('最多选择 3 项，也可以不选。');
                            return;
                          }
                          setState(
                            () => selected
                                ? selectedPreferences.add(preference)
                                : selectedPreferences.remove(preference),
                          );
                        },
                      ),
                    );
                  }),
                const SizedBox(height: 16),
                const Notice(
                  icon: Icons.spa_outlined,
                  title: '先从一件小事开始',
                  text: '所有任务都保持轻松。身份只调整场景，偏好不会提高难度，也不强迫社交。',
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: busy || role.isEmpty
                      ? null
                      : isRole
                      ? () => setState(() => onboarding = 1)
                      : finishOnboarding,
                  child: Text(
                    busy
                        ? '正在保存…'
                        : isRole
                        ? '下一步'
                        : '完成选择 · 开始探索',
                  ),
                ),
                if (!isRole)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            selectedPreferences = [];
                            finishOnboarding();
                          },
                    child: const Text('跳过，轻松开始'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget today() {
    final active = state!.activeQuestId != null;
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        Row(
          children: [
            const Text(
              '支线',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'SIDE QUEST',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 2.4,
                  color: muted,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                color: lime,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.spa_outlined, color: forest, size: 24),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('${now.month} 月 ${now.day} 日 · 给自己留一点空白', style: secondary),
        const SizedBox(height: 12),
        const Text('给日常一点新鲜。', style: heading),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Pill(roles.where((r) => r.id == role).firstOrNull?.label ?? '轻松探索'),
            ...selectedPreferences.take(2).map(Pill.new),
          ],
        ),
        const SizedBox(height: 24),
        if (state!.canRequestNext) ...[
          const BotanicalScene(height: 165),
          const SizedBox(height: 24),
          const Text(
            '今天，已经有了小发现。',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          const Text('就到这里也很好。还有兴致的话，再遇见一条支线。', style: secondary),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : () => change(repo.nextQuest),
            child: const Text('再领一条 · 自愿加一点新鲜'),
          ),
          TextButton(
            onPressed: () => setState(() => tab = 1),
            child: const Text('去看看我的探索册'),
          ),
        ] else ...[
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(24),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    const BotanicalScene(height: 175),
                    Positioned(
                      left: 18,
                      top: 16,
                      child: Pill(active ? '进行中的支线' : '今日推荐', color: paper),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        quest.title,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(quest.subtitle, style: secondary),
                      const SizedBox(height: 15),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          IconLabel(Icons.schedule, '${quest.minutes} 分钟'),
                          const IconLabel(Icons.spa_outlined, '轻松 · 无需走远'),
                        ],
                      ),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: busy ? null : openQuest,
                        child: Text(active ? '继续这条支线' : '看看这条支线'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: busy || !state!.replacementAvailable ? null : replace,
            child: Text(
              '换一个任务 ↻  ·  今日剩余 ${state!.replacementAvailable ? '1' : '0'} 次',
            ),
          ),
          if (active)
            TextButton(
              onPressed: busy ? null : stop,
              child: const Text('不方便？可以先停止', style: TextStyle(color: muted)),
            ),
        ],
        const SizedBox(height: 14),
        Notice(
          icon: Icons.auto_awesome_outlined,
          title: '已经收集 ${state!.entries.length} 次小发现',
          text: '每天推荐一条，完成后可继续领取。没有连续打卡，也不需要和谁比较。',
        ),
        const SizedBox(height: 16),
        Text(
          repo.isRemote ? '联网测试版 · 记录仅本人可访问' : '本机体验版 · 账号与记录仅在这台设备，尚未云同步',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: muted),
        ),
      ],
    );
  }

  Widget journal() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('我的探索册', style: heading),
      const SizedBox(height: 10),
      const Text('把普通日子，收成自己的小收藏。', style: secondary),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: forest,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${state!.entries.length.toString().padLeft(2, '0')}  条小发现',
                    style: const TextStyle(
                      fontSize: 25,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '只有你，拥有这本探索册。',
                    style: TextStyle(color: lime, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.spa_outlined, size: 42, color: lime),
          ],
        ),
      ),
      const SizedBox(height: 22),
      const IconLabel(Icons.lock_outline, '默认私密，不会自动公开'),
      const SizedBox(height: 20),
      if (state!.entries.isEmpty) ...[
        const SizedBox(height: 30),
        const Icon(Icons.menu_book_outlined, size: 54, color: muted),
        const SizedBox(height: 20),
        const Text(
          '下一次发现，留一页给它。',
          textAlign: TextAlign.center,
          style: secondary,
        ),
        const SizedBox(height: 25),
        OutlinedButton(
          onPressed: () => setState(() => tab = 0),
          child: const Text('去遇见今天的支线'),
        ),
      ],
      ...state!.entries.reversed.map(
        (entry) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => entryDetail(entry),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.eco_outlined, color: forest),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            entry.questTitle,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: muted),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      entry.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      formatDate(entry.createdAt),
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
  Future<void> entryDetail(JournalEntry entry) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EntryPage(entry: entry, repository: repo),
      ),
    );
    if (deleted == true) await change(repo.load);
  }

  Widget profile() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('我的', style: heading),
      const SizedBox(height: 24),
      Row(
        children: [
          const CircleAvatar(
            radius: 30,
            backgroundColor: lime,
            child: Icon(Icons.person_outline, size: 34, color: forest),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state!.profile?.nickname ?? '还没起名字的探索者',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(repo.isRemote ? '联网账号' : '仅本机测试账号', style: secondary),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 26),
      if (state!.profile == null)
        FilledButton(onPressed: authenticate, child: const Text('登录 / 创建昵称')),
      const SizedBox(height: 14),
      menu(
        Icons.tune,
        '身份与探索偏好',
        '随时调整，不增加任务难度',
        () => setState(() => onboarding = 0),
      ),
      menu(
        Icons.notifications_none,
        '提醒',
        '默认关闭 · 初版暂不发送通知',
        () => info(context, '提醒尚未启用', '初版不申请通知权限、不发送推送。后续加入用户主动开启和自选提醒时间。'),
      ),
      menu(
        Icons.photo_outlined,
        '媒体与记录规则',
        '文字可用 · 媒体入口待开放',
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const RulesPage()),
        ),
      ),
      menu(
        Icons.shield_outlined,
        '安全与隐私',
        '无定位 · 无公共动态流',
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => PrivacyPage(remote: repo.isRemote),
          ),
        ),
      ),
      if (state!.profile != null) ...[
        menu(
          Icons.file_download_outlined,
          '导出我的记录',
          '导出 JSON，不包含密码或登录凭据',
          exportRecords,
        ),
        menu(Icons.logout, '退出登录', '设备上的账号与记录仍然保留', () async {
          if (await confirm(
            context,
            '退出登录？',
            '再次登录需要昵称和密码。当前任务与文字草稿不会删除。',
            '退出登录',
          )) {
            await change(repo.logout);
          }
        }),
        menu(Icons.delete_outline, '删除账号与全部记录', '不可恢复，需要验证密码', deleteAccount),
      ],
      const SizedBox(height: 24),
      Notice(
        icon: Icons.science_outlined,
        title: '支线 0.1.0 · 文字体验版',
        text: repo.isRemote
            ? '已配置联网服务。媒体、通知与密码找回尚未开放，请勿存放敏感内容。'
            : '账号昵称仅在本安装内查重，不是全网唯一。记录保存在应用私有目录，尚未额外加密；卸载会丢失，不适合存放敏感信息。',
      ),
    ],
  );
  Widget menu(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: Icon(icon, color: forest),
        title: Text(title, style: const TextStyle(fontSize: 15)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 11, color: muted),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20, color: muted),
        onTap: busy ? null : onTap,
      ),
    ),
  );
  Future<void> exportRecords() async {
    if (!await confirm(
      context,
      '导出私密记录？',
      '文件包含全部文字记录。请只保存到你信任的位置，不包含密码与令牌。',
      '导出',
    )) {
      return;
    }
    try {
      final data = await repo.exportData();
      final file = XFile.fromData(
        Uint8List.fromList(utf8.encode(data)),
        mimeType: 'application/json',
        name: 'sidequest-journal.json',
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: ['sidequest-journal.json'],
          title: '我的支线记录',
        ),
      );
    } catch (e) {
      toast('导出未完成：$e');
    }
  }

  Future<void> deleteAccount() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账号与全部记录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('操作不可恢复。输入密码确认，建议先导出记录。'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: '账号密码'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (password != null && await change(() => repo.deleteAccount(password))) {
      toast('账号与应用内记录已删除。导出和分享的副本需要自行删除。');
    }
  }
}
