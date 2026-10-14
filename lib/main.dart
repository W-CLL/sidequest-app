import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain.dart';
import 'repository.dart';
import 'pages.dart';
import 'widgets.dart';
import 'media_widgets.dart';
import 'sync_boot_io.dart' if (dart.library.js_interop) 'sync_boot_web.dart' as sync_boot;
import 'voice.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    SideQuestApp(
      repository: createRepository(
        apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
      ),
    ),
  );
  unawaited(sync_boot.initializeBackgroundSync());
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
    home: repository.isConfigured
        ? QuestHome(repository: repository)
        : const ConfigurationPage(),
  );
}

class ConfigurationPage extends StatelessWidget {
  const ConfigurationPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('支线')),
    body: const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.settings_ethernet, size: 44, color: forest),
            SizedBox(height: 16),
            Text(
              '暂时连不上服务',
              key: Key('service-not-configured'),
              style: heading,
            ),
            SizedBox(height: 12),
            Text(
              '请更新到最新版本后再试。',
              style: secondary,
            ),
          ],
        ),
      ),
    ),
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
  final _search = TextEditingController();
  Timer? _searchDebounce;
  Timer? _syncRefreshDebounce;
  StreamSubscription<SyncSummary>? _syncSubscription;
  SyncSummary? _syncSummary;
  List<JournalEntry> _journalEntries = [];
  String? _journalCursor, _journalError;
  bool _journalLoading = false;
  int _journalGeneration = 0;
  QuestRepository get repo => widget.repository;
  Quest get quest =>
      questById(state!.activeQuestId ?? state!.recommendedQuestId);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncSubscription = repo.syncUpdates.listen((summary) {
      if (mounted) setState(() => _syncSummary = summary);
      _syncRefreshDebounce?.cancel();
      _syncRefreshDebounce = Timer(
        const Duration(milliseconds: 250),
        () => unawaited(_refreshAfterSync()),
      );
    });
    boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounce?.cancel();
    _syncRefreshDebounce?.cancel();
    _search.dispose();
    unawaited(_syncSubscription?.cancel());
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
      if (snapshot.profile != null) unawaited(_loadJournal());
      unawaited(_refreshSyncSummary());
    } catch (e) {
      repo.reportProblem(e, 'home.load');
      if (mounted) setState(() => error = userMessageFor(e));
    }
  }

  Future<void> _refreshSyncSummary() async {
    try {
      final summary = await repo.getSyncSummary();
      if (mounted) setState(() => _syncSummary = summary);
    } catch (_) {
      /* A failed status check must not hide existing records. */
    }
  }

  Future<void> _refreshAfterSync() async {
    final accountId = state?.profile?.id;
    if (accountId == null) return;
    try {
      final snapshot = await repo.load();
      if (!mounted ||
          state?.profile?.id != accountId ||
          snapshot.profile?.id != accountId) {
        return;
      }
      final fresh = {for (final entry in snapshot.entries) entry.id: entry};
      setState(() {
        _acceptSnapshot(snapshot);
        _journalEntries = _journalEntries
            .map((entry) => fresh[entry.id] ?? entry)
            .toList();
      });
    } catch (_) {
      /* Keep the readable cache while a status refresh is unavailable. */
    }
  }

  Future<void> _loadJournal({bool append = false}) async {
    if (state?.profile == null) return;
    if (append && (_journalLoading || _journalCursor == null)) return;
    final generation = append ? _journalGeneration : ++_journalGeneration;
    final accountId = state!.profile!.id;
    setState(() {
      _journalLoading = true;
      _journalError = null;
    });
    try {
      final page = await repo.queryEntries(
        query: _search.text.trim(),
        cursor: append ? _journalCursor : null,
      );
      if (!mounted ||
          generation != _journalGeneration ||
          state?.profile?.id != accountId) {
        return;
      }
      final merged = <String, JournalEntry>{
        if (append)
          for (final entry in _journalEntries) entry.id: entry,
        for (final entry in page.entries) entry.id: entry,
      };
      setState(() {
        _journalEntries = merged.values.toList();
        _journalCursor = page.nextCursor;
      });
    } catch (error) {
      repo.reportProblem(error, 'journal.load');
      if (mounted && generation == _journalGeneration) {
        setState(() => _journalError = userMessageFor(error));
      }
    } finally {
      if (mounted && generation == _journalGeneration) {
        setState(() => _journalLoading = false);
      }
    }
  }

  Future<void> _openSync() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SyncStatusPage(
          repository: repo,
          onLogin: () async {
            final result = await Navigator.of(context).push<AppSnapshot>(
              MaterialPageRoute(
                builder: (_) =>
                    LoginPage(repository: repo, reauthenticate: true),
              ),
            );
            if (mounted && result != null) {
              setState(() => _acceptSnapshot(result));
            }
          },
        ),
      ),
    );
    if (!mounted) return;
    await change(repo.load);
    await _refreshSyncSummary();
    await _loadJournal();
  }

  void toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _acceptSnapshot(AppSnapshot result) {
    if (state?.profile?.id != result.profile?.id) {
      _journalGeneration++;
      _journalEntries = [];
      _journalCursor = null;
      _journalError = null;
      _journalLoading = false;
      _search.clear();
      _syncSummary = null;
    }
    state = result;
    if (result.profile != null) {
      role = result.profile!.role;
      selectedPreferences = List.of(result.profile!.preferences);
    }
  }

  Future<bool> change(Future<AppSnapshot> Function() action) async {
    if (busy) return false;
    setState(() => busy = true);
    try {
      final result = await action();
      if (mounted) {
        setState(() {
          _acceptSnapshot(result);
        });
      }
      return true;
    } catch (e) {
      repo.reportProblem(e, 'action');
      toast(userMessageFor(e));
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
      repo.reportProblem(e, 'preferences.local');
      toast('偏好没存上，请再试一次。');
    }
  }

  Future<bool> authenticate() async {
    if (state!.profile != null) return true;
    final result = await Navigator.of(context).push<AppSnapshot>(
      MaterialPageRoute(builder: (_) => LoginPage(repository: repo)),
    );
    if (!mounted || result == null) return false;
    setState(() {
      _acceptSnapshot(result);
    });
    unawaited(_loadJournal());
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
      toast('已恢复这个账号的进度，请从首页继续。');
      return;
    }
    if (state!.activeQuestId == null && !await change(repo.claim)) return;
    if (!mounted) return;
    final previousIds = state!.entries.map((entry) => entry.id).toSet();
    final completed = await Navigator.of(context).push<AppSnapshot>(
      MaterialPageRoute(
        builder: (_) => RecordPage(
          repository: repo,
          quest: quest,
          initialDraft: state!.draft,
          initialAttachments: state!.draftAttachments,
          accountId: state!.profile?.id,
        ),
      ),
    );
    if (!mounted) return;
    if (completed != null) setState(() => _acceptSnapshot(completed));
    await change(repo.load);
    if (completed != null && mounted) {
      final additions =
          completed.entries
              .where((entry) => !previousIds.contains(entry.id))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final completedEntry = additions.isEmpty ? null : additions.first;
      final latest =
          state!.entries
              .where((entry) => entry.id == completedEntry?.id)
              .firstOrNull ??
          completedEntry;
      final saved = latest?.isSynced == true;
      unawaited(_loadJournal());
      unawaited(_refreshSyncSummary());
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.spa_outlined, color: forest, size: 48),
          title: Text(saved ? '已保存到探索册' : '已记下，等待同步'),
          content: Text(
            saved ? '已保存到探索册，随时可以回看。' : '稍后会自动同步；也可以在“同步”里立即上传。',
          ),
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
              child: const Text('查看探索册'),
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
      toast('今天已经换过一次。现在不合适，可以先放一放。');
      return;
    }
    if (await confirm(context, '换个活动？', '每天可更换一次，更换后当前草稿会清空。', '换个活动')) {
      if (await change(repo.replace)) toast('已更换，今天的更换次数已用完。');
    }
  }

  Future<void> stop() async {
    if (await confirm(context, '先放一放？', '草稿会保留，之后可以继续。', '先放一放')) {
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
        onDestinationSelected: (i) {
          setState(() => tab = i);
          if (i == 1) unawaited(_loadJournal());
          if (i == 2) unawaited(_refreshSyncSummary());
        },
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
    final media = MediaQuery.of(context);
    final singleColumn =
        media.size.width < 360 || media.textScaler.scale(1) > 1.2;
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
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: KeyedSubtree(
              key: ValueKey(onboarding),
              child: ListView(
                key: const ValueKey('onboarding-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                children: [
                  Text(isRole ? '此刻，你的生活角色？' : '你更喜欢怎样探索？', style: heading),
                  const SizedBox(height: 6),
                  Text(
                    isRole
                        ? '选一个现在最贴近的身份，之后随时可改。'
                        : '选择你喜欢的方式，之后可以修改。最多选 3 项，也可以跳过。',
                    style: secondary,
                  ),
                  const SizedBox(height: 14),
                  if (isRole)
                    ...roles.asMap().entries.map((entry) {
                      final option = entry.value;
                      final selected = role == option.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Semantics(
                          button: true,
                          selected: selected,
                          child: Material(
                            color: selected ? pale : Colors.white,
                            shape: RoundedRectangleBorder(
                              side: BorderSide(
                                color: selected ? forest : border,
                              ),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: ValueKey('role-${option.id}'),
                              onTap: () => setState(() => role = option.id),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 52,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 7,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        roleIcons[entry.key],
                                        color: forest,
                                        size: 21,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              option.label,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            if (selected) ...[
                                              const SizedBox(height: 1),
                                              Text(
                                                option.subtitle,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  height: 1.3,
                                                  color: muted,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        selected
                                            ? Icons.check_circle
                                            : Icons.circle_outlined,
                                        color: selected ? forest : border,
                                        size: 20,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    })
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const gap = 8.0;
                        final itemWidth = singleColumn
                            ? constraints.maxWidth
                            : (constraints.maxWidth - gap) / 2;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: preferences.map((preference) {
                            final checked = selectedPreferences.contains(
                              preference,
                            );
                            return SizedBox(
                              width: itemWidth,
                              child: Semantics(
                                button: true,
                                selected: checked,
                                child: Material(
                                  color: checked ? lime : Colors.white,
                                  shape: RoundedRectangleBorder(
                                    side: BorderSide(
                                      color: checked ? forest : border,
                                    ),
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    key: ValueKey('preference-$preference'),
                                    onTap: () {
                                      if (!checked &&
                                          selectedPreferences.length >= 3) {
                                        toast('最多选择 3 项，也可以不选。');
                                        return;
                                      }
                                      setState(
                                        () => checked
                                            ? selectedPreferences.remove(
                                                preference,
                                              )
                                            : selectedPreferences.add(
                                                preference,
                                              ),
                                      );
                                    },
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 52,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                preference,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Icon(
                                              checked
                                                  ? Icons.check_circle
                                                  : Icons.circle_outlined,
                                              size: 20,
                                              color: checked ? forest : border,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: ColoredBox(
        color: paper,
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(
                      key: const ValueKey('onboarding-next-action'),
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
                        key: const ValueKey('preferences-skip-action'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        onPressed: busy
                            ? null
                            : () {
                                selectedPreferences = [];
                                finishOnboarding();
                              },
                        child: const Text('跳过，直接开始'),
                      ),
                  ],
                ),
              ),
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
      key: const ValueKey('today-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      children: [
        Row(
          children: [
            const Text(
              '支线',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
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
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                color: lime,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.spa_outlined, color: forest, size: 22),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text('${now.month} 月 ${now.day} 日 · 给自己留一点空白', style: secondary),
        const SizedBox(height: 5),
        const Text(
          '给日常一点新鲜。',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Pill(roles.where((r) => r.id == role).firstOrNull?.label ?? '轻松探索'),
            ...selectedPreferences.take(2).map(Pill.new),
          ],
        ),
        const SizedBox(height: 14),
        if (state!.canRequestNext) ...[
          const BotanicalScene(height: 120),
          const SizedBox(height: 14),
          const Text(
            '今天，已经有了小发现。',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text('就到这里也很好，想继续时再看看。', style: secondary),
          const SizedBox(height: 14),
          KeyedSubtree(
            key: const ValueKey('next-quest-action'),
            child: FilledButton(
              key: const ValueKey('today-primary-action'),
              onPressed: busy ? null : () => change(repo.nextQuest),
              child: const Text('继续探索'),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => tab = 1),
            child: const Text('查看探索册'),
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
                    const BotanicalScene(height: 120),
                    Positioned(
                      left: 14,
                      top: 12,
                      child: Pill(active ? '正在进行' : '今日推荐', color: paper),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        quest.title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(quest.subtitle, style: secondary),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          IconLabel(Icons.schedule, '${quest.minutes} 分钟'),
                          const IconLabel(Icons.spa_outlined, '轻松 · 无需走远'),
                        ],
                      ),
                      const SizedBox(height: 14),
                      FilledButton(
                        key: const ValueKey('today-primary-action'),
                        onPressed: busy ? null : openQuest,
                        child: Text(active ? '继续记录' : '查看详情'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          if (active)
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const ValueKey('replace-quest-action'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: busy || !state!.replacementAvailable
                        ? null
                        : replace,
                    child: Text(
                      '换个活动 · ${state!.replacementAvailable ? '剩 1 次' : '今天已换'}',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextButton(
                    key: const ValueKey('stop-quest-action'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: busy ? null : stop,
                    child: const Text('先放一放', style: TextStyle(color: muted)),
                  ),
                ),
              ],
            )
          else
            TextButton(
              key: const ValueKey('replace-quest-action'),
              style: TextButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
              onPressed: busy || !state!.replacementAvailable ? null : replace,
              child: Text(
                '换个活动 · 今日剩余 ${state!.replacementAvailable ? '1' : '0'} 次',
              ),
            ),
        ],
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: pale,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_outlined, color: forest, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '探索册已有 ${state!.entryCount} 条记录',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          repo.isWebClient ? '写下的会保存 · 只有你能看到' : '先记下，稍后自动同步 · 只有你能看到',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: muted),
        ),
      ],
    );
  }

  Widget journal() => ListView(
    key: const ValueKey('journal-scroll'),
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    children: [
      const Text('我的探索册', style: heading),
      const SizedBox(height: 5),
      const Text('把普通日子，收成自己的小收藏。', style: secondary),
      const SizedBox(height: 14),
      TextField(
        key: const Key('journal-search-field'),
        controller: _search,
        decoration: InputDecoration(
          hintText: '搜索标题或正文',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('journal-clear-search'),
                  tooltip: '清空搜索',
                  onPressed: () {
                    _search.clear();
                    unawaited(_loadJournal());
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
        onChanged: (_) {
          _searchDebounce?.cancel();
          _journalGeneration++;
          setState(() {});
          _searchDebounce = Timer(
            const Duration(milliseconds: 350),
            () => unawaited(_loadJournal()),
          );
        },
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        decoration: BoxDecoration(
          color: forest,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${state!.entryCount.toString().padLeft(2, '0')}  条小发现',
                    style: const TextStyle(
                      fontSize: 22,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    '只有你，拥有这本探索册。',
                    style: TextStyle(color: lime, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.spa_outlined, size: 34, color: lime),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const IconLabel(Icons.lock_outline, '只有你能看到，不会公开'),
      const SizedBox(height: 12),
      if (_journalError != null) ErrorNotice(_journalError!),
      if (_journalEntries.isEmpty &&
          !_journalLoading &&
          _search.text.isNotEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('没有找到匹配的记录', key: Key('journal-no-results')),
        ),
      if (_journalEntries.isEmpty &&
          _search.text.isEmpty &&
          !_journalLoading) ...[
        const SizedBox(height: 12),
        const Icon(Icons.menu_book_outlined, size: 44, color: muted),
        const SizedBox(height: 12),
        const Text(
          '下一次发现，留一页给它。',
          textAlign: TextAlign.center,
          style: secondary,
        ),
        const SizedBox(height: 14),
        OutlinedButton(
          key: const ValueKey('journal-empty-action'),
          onPressed: () => setState(() => tab = 0),
          child: const Text('看看今天的活动'),
        ),
      ],
      ..._journalEntries.map(
        (entry) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(17),
            child: InkWell(
              key: ValueKey('journal-entry-${entry.id}'),
              borderRadius: BorderRadius.circular(17),
              onTap: () => entryDetail(entry),
              child: Padding(
                padding: const EdgeInsets.all(16),
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
                    const SizedBox(height: 9),
                    Text(
                      entry.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${formatDate(entry.createdAt)} · ${syncStatusLabel(entry.syncStatus)}${entry.attachments.isEmpty ? '' : ' · ${entry.attachments.length} 个附件'}',
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      if (_journalLoading)
        const Padding(padding: EdgeInsets.all(12), child: Text('正在读取记录…')),
      if (_journalCursor != null)
        OutlinedButton(
          key: const Key('journal-load-more'),
          onPressed: _journalLoading ? null : () => _loadJournal(append: true),
          child: const Text('加载更多'),
        ),
    ],
  );
  Future<void> entryDetail(JournalEntry entry) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EntryPage(entry: entry, repository: repo),
      ),
    );
    if (deleted == true) {
      await change(repo.load);
      if (mounted) await _loadJournal();
    }
  }

  Widget profile() {
    final settings = <Widget>[
      menu(
        Icons.tune,
        '身份与探索偏好',
        '随时调整，不增加探索难度',
        () => setState(() => onboarding = 0),
      ),
      menu(
        Icons.info_outline,
        '版本说明',
        '0.2.0 · 多媒体记录',
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => VersionPage(remote: repo.isRemote, web: repo.isWebClient),
          ),
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
    ];
    final account = <Widget>[
      // 网页版没有本地同步队列：不显示「同步」入口。
      if (!repo.isWebClient)
        menu(
          Icons.cloud_upload_outlined,
          '同步',
          _syncSummary?.requiresLogin == true
              ? '登录已过期 · 点这里重新登录'
              : _syncSummary == null
              ? '稍后自动同步'
              : '待同步 ${_syncSummary!.pending} · 失败 ${_syncSummary!.failed}',
          _openSync,
        ),
      menu(Icons.logout, '退出登录', repo.isWebClient ? '退出后要重新登录' : '没同步的内容留在手机里，登录后继续', () async {
        if (await confirm(
          context,
          '退出登录？',
          repo.isWebClient
              ? '退出登录后，需要昵称和密码重新登录。'
              : '再次登录需要昵称和密码。没同步的内容和草稿会留在手机里，别的账号看不到。',
          '退出登录',
        )) {
          await change(() => repo.logout());
        }
      }),
      menu(
        Icons.delete_outline,
        '删除账号与全部记录',
        '不可恢复，需要验证密码',
        deleteAccount,
        danger: true,
      ),
    ];
    return ListView(
      key: const ValueKey('profile-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        const Text('我的', style: heading),
        const SizedBox(height: 12),
        Row(
          children: [
            const CircleAvatar(
              radius: 25,
              backgroundColor: lime,
              child: Icon(Icons.person_outline, size: 28, color: forest),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state!.profile?.nickname ?? '还没起名字的探索者',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text('你的账号', style: secondary),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (state!.profile == null) ...[
          FilledButton(
            key: const ValueKey('profile-login-action'),
            onPressed: authenticate,
            child: const Text('登录 / 创建昵称'),
          ),
          const SizedBox(height: 12),
        ],
        menuGroup(settings),
        if (state!.profile != null) ...[
          const SizedBox(height: 12),
          menuGroup(account),
        ],
        const SizedBox(height: 10),
        Text(
          '没同步的内容请勿清理应用数据',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: muted),
        ),
      ],
    );
  }

  Widget menuGroup(List<Widget> items) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          items[index],
          if (index != items.length - 1)
            const Divider(height: 1, indent: 52, endIndent: 14),
        ],
      ],
    ),
  );

  Widget menu(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap, {
    bool danger = false,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 54),
    child: ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Icon(
        icon,
        color: danger ? Theme.of(context).colorScheme.error : forest,
        size: 22,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: danger ? Theme.of(context).colorScheme.error : ink,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11, height: 1.3, color: muted),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20, color: muted),
      onTap: busy ? null : onTap,
    ),
  );

  Future<void> deleteAccount() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账号与全部记录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('操作不可恢复，将删除账号、记录和媒体。输入密码确认。'),
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
      toast('账号与应用内记录已删除。分享出去的副本需要自行删除。');
    }
  }
}
