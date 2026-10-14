import 'package:flutter/material.dart';

import 'domain.dart';
import 'repository.dart';
import 'voice.dart';

export 'record_pages.dart';

const _paper = Color(0xFFF7F6F0);
const _ink = Color(0xFF203B31);
const _forest = Color(0xFF234D3C);
const _lime = Color(0xFFDFECAC);
const _pale = Color(0xFFEEF1E6);
const _muted = Color(0xFF69756C);

String _errorText(Object error) => userMessageFor(error);

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.repository,
    this.reauthenticate = false,
  });
  final QuestRepository repository;
  final bool reauthenticate;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _nickname = TextEditingController();
  final _password = TextEditingController();
  bool _register = true;
  bool _accepted = false;
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _register = !widget.reauthenticate;
    if (widget.reauthenticate) {
      widget.repository
          .load()
          .then((state) {
            if (mounted && _nickname.text.isEmpty) {
              _nickname.text = state.profile?.nickname ?? '';
            }
          })
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    _nickname.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (_nickname.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = '请填写昵称和密码。');
      return;
    }
    if (_register && !_accepted) {
      setState(() => _error = '请先确认隐私说明。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = _register
          ? await widget.repository.register(
              _nickname.text.trim(),
              _password.text,
            )
          : await widget.repository.login(
              _nickname.text.trim(),
              _password.text,
            );
      if (mounted) Navigator.of(context).pop(snapshot);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(title: const Text('登录与账号')),
    body: SafeArea(
      child: ListView(
        key: const Key('auth-scroll'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: _lime,
                child: Icon(Icons.spa_outlined, color: _forest, size: 27),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '从一件小事开始',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      '开始后，进度会为你保留。不需要手机号。',
                      style: TextStyle(color: _muted, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('注册')),
              ButtonSegment(value: false, label: Text('登录')),
            ],
            selected: {_register},
            onSelectionChanged: _busy
                ? null
                : (selection) => setState(() {
                    _register = selection.first;
                    _error = null;
                    _accepted = false;
                  }),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('auth-nickname-field'),
            controller: _nickname,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            decoration: InputDecoration(
              labelText: '昵称',
              hintText: '2–20 个字',
              helperText: '不能与当前服务中的已有账号重复',
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('auth-password-field'),
            controller: _password,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            autofillHints: [
              _register ? AutofillHints.newPassword : AutofillHints.password,
            ],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '密码',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              '8–128 个字符；建议不要与别处共用密码。',
              key: Key('auth-password-requirements'),
              style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
            ),
          ),
          if (_register) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('auth-consent'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _accepted,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _accepted = value ?? false),
              title: const Text(
                '我已了解记录的保存方式与隐私说明。',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ],
          _Panel(
            icon: Icons.info_outline_rounded,
            title: widget.repository.isWebClient ? '写下来，再保存' : '先记下，再同步',
            text: widget.repository.isWebClient
                ? '创建账号需要网络；写下的内容会保存到你的账号里。'
                : '创建账号需要网络；已经记下的内容会留在手机里，稍后自动同步。',
          ),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PrivacyPage(remote: widget.repository.isRemote),
                ),
              ),
              child: const Text('查看隐私说明'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            _ErrorLabel(_error!),
          ],
          const SizedBox(height: 8),
        ],
      ),
    ),
    bottomNavigationBar: AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: FilledButton.icon(
          key: const Key('auth-submit-action'),
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const _Spinner()
              : const Icon(Icons.arrow_forward_rounded),
          label: Text(
            _busy
                ? '正在处理…'
                : _register
                ? '创建账号并继续'
                : '登录并继续',
          ),
        ),
      ),
    ),
  );
}

class QuestDetail extends StatelessWidget {
  const QuestDetail({
    super.key,
    required this.quest,
    required this.role,
    required this.active,
  });
  final Quest quest;
  final String role;
  final bool active;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(title: const Text('探索详情')),
    body: SafeArea(
      child: ListView(
        key: const Key('quest-detail-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Tag(quest.category),
              _Tag('约 ${quest.minutes} 分钟'),
              const _Tag('轻松完成'),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            quest.title,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            quest.subtitle,
            style: const TextStyle(fontSize: 16, color: _muted, height: 1.6),
          ),
          const SizedBox(height: 16),
          _QuestArt(quest: quest),
          if (quest.roleHints[role] != null) ...[
            const SizedBox(height: 14),
            _Panel(
              icon: Icons.wb_sunny_outlined,
              title: '适合你的一个时刻',
              text: quest.roleHints[role]!,
            ),
          ],
          const SizedBox(height: 22),
          const Text(
            '可以这样开始',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 14),
          for (var index = 0; index < quest.steps.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: _lime,
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(fontSize: 12, color: _forest),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      quest.steps[index],
                      style: const TextStyle(
                        fontSize: 15,
                        color: _ink,
                        height: 1.65,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _Panel(icon: Icons.shield_outlined, title: '留意一下', text: quest.hint),
        ],
      ),
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: FilledButton.icon(
        key: const Key('quest-primary-action'),
        onPressed: () => Navigator.of(context).pop(true),
        icon: Icon(active ? Icons.edit_outlined : Icons.explore_outlined),
        label: Text(active ? '继续记录' : '开始'),
      ),
    ),
  );
}

class VersionPage extends StatelessWidget {
  const VersionPage({super.key, required this.remote, this.web = false});

  final bool remote, web;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(title: const Text('版本说明')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _LeafMark(),
            const SizedBox(height: 20),
            const Text(
              '0.2.0 · 每天一条支线',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w700,
                color: _ink,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '每天一条小支线，记下发现，随时回看。',
              style: TextStyle(color: _muted, height: 1.7),
            ),
            const SizedBox(height: 20),
            const _Section(
              '可以做什么',
              '40 条小支线，会参考你的偏好来推荐。记录能写文字、放图片、视频和语音，也能搜索和编辑。',
            ),
            _Section(
              '保存方式',
              web
                  ? '内容直接保存到你的账号里，换个设备也能接着看。'
                  : '内容先存在手机里，稍后自动同步；卸载前请确认同步完成。',
            ),
            const _Section('请留意', '不要用它保存证件、密码这类敏感资料。'),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PrivacyPage(remote: remote),
                ),
              ),
              icon: const Icon(Icons.shield_outlined),
              label: const Text('安全与隐私'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Kept for callers from earlier alpha builds. New navigation should use
/// [VersionPage] so the current save mode is described accurately.
class RulesPage extends StatelessWidget {
  const RulesPage({super.key});

  @override
  Widget build(BuildContext context) => const VersionPage(remote: false);
}

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key, required this.remote});
  final bool remote;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(title: const Text('安全与隐私')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _LeafMark(),
            const SizedBox(height: 24),
            const Text(
              '你的生活，不需要被围观',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w700,
                color: _ink,
              ),
            ),
            const SizedBox(height: 16),
            _Panel(
              icon: Icons.info_outline_rounded,
              title: '账号与内容',
              text: '账号和记录会同步到服务；还没同步的内容先留在手机里，同步完成前请保留应用数据。',
            ),
            const SizedBox(height: 28),
            const _Section(
              '只用昵称和密码',
              '不收集手机号。身份只用来选择合适场景，不代表年龄验证，随时可以修改。',
            ),
            _Section(
              '数据与安全',
              '记录和媒体的查看需要账号验证；卸载或清除数据会丢失还没同步的内容。请勿保存证件、密码等敏感资料。',
            ),
            const _Section(
              '不追踪位置，不索取无关权限',
              '不请求定位，不记录行动轨迹。相册和录音只在你使用时询问；没有拍摄入口，也没有定时通知。',
            ),
            const _Section(
              '只有你能看到，分享由你决定',
              '没有公开信息流，记录不会自动公开。生成分享卡前会请你确认，卡片不包含昵称和身份；分享出去的文件需要你自行保管。',
            ),
            const _Section(
              '删除与分享',
              '可删除单条记录，或验证密码后删除账号，删除不可撤销。分享卡默认只有文字，最多可选 5 张图片；语音和视频不会加入。',
            ),
            const _Section(
              '不以压力换取完成',
              '所有探索都轻量、低风险，不强制消费、社交或运动。每天可以更换一次；任何时候不合适，都可以先放一放。没有连续签到，也没有惩罚。',
            ),
          ],
        ),
      ),
    ),
  );
}

class _LeafMark extends StatelessWidget {
  const _LeafMark();
  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: CircleAvatar(
      radius: 34,
      backgroundColor: _lime,
      child: Icon(Icons.spa_outlined, color: _forest, size: 36),
    ),
  );
}

class _QuestArt extends StatelessWidget {
  const _QuestArt({required this.quest});
  final Quest quest;
  @override
  Widget build(BuildContext context) => Container(
    height: 80,
    decoration: BoxDecoration(
      color: _pale,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          right: 24,
          top: 12,
          child: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: _lime,
              shape: BoxShape.circle,
            ),
          ),
        ),
        Icon(
          quest.category == '创作'
              ? Icons.draw_outlined
              : quest.category == '休息'
              ? Icons.weekend_outlined
              : Icons.spa_outlined,
          size: 48,
          color: _forest,
        ),
      ],
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    widthFactor: 1,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _pale,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: _forest,
        ),
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _pale,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: _forest),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  color: _muted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.text);
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
        const SizedBox(height: 9),
        Text(
          text,
          style: const TextStyle(fontSize: 14, color: _muted, height: 1.8),
        ),
      ],
    ),
  );
}

class _ErrorLabel extends StatelessWidget {
  const _ErrorLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6E9E2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF8C4936),
          fontSize: 13,
          height: 1.5,
        ),
      ),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
