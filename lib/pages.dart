import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'domain.dart';
import 'repository.dart';

const _paper = Color(0xFFF7F6F0);
const _ink = Color(0xFF203B31);
const _forest = Color(0xFF234D3C);
const _lime = Color(0xFFDFECAC);
const _pale = Color(0xFFEEF1E6);
const _muted = Color(0xFF69756C);
const _line = Color(0xFFE2E6DB);

String _errorText(Object error) =>
    error is QuestException ? error.message : '这次没有保存成功，请稍后重试。内容仍保留在当前页面。';
String _date(DateTime value) {
  final date = value.toLocal();
  return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.repository});
  final QuestRepository repository;
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
      setState(() => _error = '请先确认已了解内测账号和隐私说明。');
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
    appBar: AppBar(title: const Text('给探索留一个名字')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: [
          const _LeafMark(),
          const SizedBox(height: 22),
          const Text(
            '你的支线，从这里开始',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '选中的支线会为你保留。用昵称和密码登录，不需要手机号。',
            style: TextStyle(color: _muted, height: 1.7),
          ),
          const SizedBox(height: 24),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('第一次来')),
              ButtonSegment(value: false, label: Text('已有账号')),
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
          const SizedBox(height: 24),
          TextField(
            controller: _nickname,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            decoration: InputDecoration(
              labelText: '昵称',
              hintText: '为自己起一个名字',
              helperText: widget.repository.isRemote
                  ? '昵称不能与这个服务中的已有账号重复'
                  : '单机内测：仅检查当前安装内的昵称',
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
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
              hintText: '8–128 个字符，使用独立的测试密码',
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
          const SizedBox(height: 20),
          _Panel(
            icon: Icons.info_outline_rounded,
            title: widget.repository.isRemote ? '连接服务的内测账号' : '当前是单机体验模式',
            text: widget.repository.isRemote
                ? '账号与记录会发送到已配置的服务。暂不支持密码找回，请勿使用其他网站的密码。'
                : '账号与记录仅存在当前应用安装中，昵称不代表全平台唯一。卸载或清除数据可能丢失所有记录，暂不支持密码找回。',
          ),
          if (_register) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _accepted,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _accepted = value ?? false),
              title: const Text(
                '我已了解当前账号模式、隐私说明与无法找回密码的限制。',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PrivacyPage(remote: widget.repository.isRemote),
                ),
              ),
              child: const Text('查看隐私与内测说明'),
            ),
          ),
          if (_error != null) _ErrorLabel(_error!),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const _Spinner()
                : const Icon(Icons.arrow_forward_rounded),
            label: Text(
              _busy
                  ? '正在处理…'
                  : _register
                  ? '创建账号，继续支线'
                  : '登录，继续支线',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '昵称用于区分账号，密码用于验证身份。不收集手机号，不公开你的探索记录。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
          ),
        ],
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
    appBar: AppBar(title: const Text('一条小小的支线')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _QuestArt(quest: quest),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Tag(quest.category),
              _Tag('约 ${quest.minutes} 分钟'),
              const _Tag('轻松完成'),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            quest.title,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            quest.subtitle,
            style: const TextStyle(fontSize: 16, color: _muted, height: 1.6),
          ),
          if (quest.roleHints[role] != null) ...[
            const SizedBox(height: 16),
            _Panel(
              icon: Icons.wb_sunny_outlined,
              title: '适合你的一个时刻',
              text: quest.roleHints[role]!,
            ),
          ],
          const SizedBox(height: 28),
          const Text(
            '可以这样开始',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 16),
          for (var index = 0; index < quest.steps.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
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
          _Panel(
            icon: Icons.shield_outlined,
            title: '舒服和安全，比完成更重要',
            text: quest.hint,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: Icon(active ? Icons.edit_outlined : Icons.explore_outlined),
            label: Text(active ? '记录这次发现' : '选择这条支线'),
          ),
          const SizedBox(height: 12),
          const Text(
            '不用出远门，不强迫拍照，不要求完美。不适合时随时停止，不会受到惩罚。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
          ),
        ],
      ),
    ),
  );
}

class RecordPage extends StatefulWidget {
  const RecordPage({
    super.key,
    required this.repository,
    required this.quest,
    required this.initialDraft,
  });
  final QuestRepository repository;
  final Quest quest;
  final String initialDraft;
  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  late final TextEditingController _text;
  late String _savedText;
  bool _busy = false;
  bool _allowPop = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialDraft);
    _savedText = widget.initialDraft;
    _text.addListener(_textChanged);
  }

  void _textChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _text.removeListener(_textChanged);
    _text.dispose();
    super.dispose();
  }

  Future<bool> _save({bool notify = false}) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.saveDraft(_text.text);
      _savedText = _text.text;
      if (notify && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('草稿已保存，可以晚一点继续。')));
      }
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || _allowPop) return;
    if (_text.text != _savedText && !await _save()) return;
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _complete() async {
    if (_busy) return;
    final value = _text.text.trim();
    if (value.isEmpty || value.runes.length > 300) {
      setState(() => _error = '写下一点发现吧，1 到 300 个字就足够。');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await widget.repository.complete(value);
      if (!mounted) return;
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(snapshot);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<AppSnapshot>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _leave();
    },
    child: Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('留住这次发现'),
        leading: IconButton(
          tooltip: '保存并返回',
          onPressed: _busy ? null : _leave,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _save(notify: true),
            child: const Text('存草稿'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _Tag(widget.quest.title),
            const SizedBox(height: 20),
            const Text(
              '这一刻，你发现了什么？',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w700,
                color: _ink,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '一句话、几个词，都算数。不用证明你做过，也不用写得漂亮。',
              style: TextStyle(color: _muted, height: 1.7),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _text,
              readOnly: _busy,
              minLines: 7,
              maxLines: 12,
              inputFormatters: [const _CodePointLimit(300)],
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: '比如：窗边叶子的绿，比杯子上的更柔和。',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${_text.text.runes.length} / 300',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '照片、声音和视频',
              style: TextStyle(fontWeight: FontWeight.w600, color: _ink),
            ),
            const SizedBox(height: 10),
            const Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_outlined, size: 18),
                      SizedBox(width: 6),
                      Text('图片'),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic_none_rounded, size: 18),
                      SizedBox(width: 6),
                      Text('录音'),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam_outlined, size: 18),
                      SizedBox(width: 6),
                      Text('视频'),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RulesPage()),
                ),
                child: const Text('本版仅支持文字 · 查看后续媒体规则'),
              ),
            ),
            const SizedBox(height: 12),
            _Panel(
              icon: Icons.lock_outline_rounded,
              title: '只收进你的探索册',
              text: widget.repository.isRemote
                  ? '这条文字会保存到已配置服务的私人账号，不会自动公开。不要记录他人的对话、住址或敏感信息。'
                  : '这条文字保存在当前设备的应用数据中，不会自动公开。本地记录未额外加密，请勿填写敏感信息。',
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              _ErrorLabel(_error!),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _complete,
              icon: _busy ? const _Spinner() : const Icon(Icons.check_rounded),
              label: Text(_busy ? '正在保存…' : '完成，收进探索册'),
            ),
            const SizedBox(height: 10),
            const Text(
              '返回时会尝试保存草稿；强制关闭前请主动存草稿。',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    ),
  );
}

class EntryPage extends StatefulWidget {
  const EntryPage({super.key, required this.entry, required this.repository});
  final JournalEntry entry;
  final QuestRepository repository;
  @override
  State<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<EntryPage> {
  final _cardKey = GlobalKey();
  bool _busy = false;
  String? _error;
  Future<void> _share() async {
    if (_busy) return;
    final accepted = await _confirm(
      context,
      '分享前，再看一眼',
      '卡片会包含任务、日期和这段记录，不含昵称或身份。请检查文字中是否包含住址、真实姓名或他人隐私。分享后，接收方可保存或转发。',
      '生成并分享卡片',
    );
    if (!accepted || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    ui.Image? image;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _cardKey.currentContext == null) return;
      await Scrollable.ensureVisible(_cardKey.currentContext!, alignment: 0);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      image = await boundary.toImage(pixelRatio: 2);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw const QuestException('卡片生成失败，请重试。');
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              byteData.buffer.asUint8List(),
              mimeType: 'image/png',
              name: 'sidequest-card.png',
            ),
          ],
          fileNameOverrides: const ['sidequest-card.png'],
          title: '一条小小的支线',
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is QuestException
              ? error.message
              : '暂时无法调起分享，请稍后重试。你的记录不会受到影响。',
        );
      }
    } finally {
      image?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final accepted = await _confirm(
      context,
      '删除这条记录？',
      '删除后不能恢复。已经分享出去的卡片不会被一起删除，其他人的副本也无法撤回。',
      '删除记录',
    );
    if (!accepted || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.deleteEntry(widget.entry.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(
      title: const Text('一页探索'),
      actions: [
        IconButton(
          tooltip: '删除记录',
          onPressed: _busy ? null : _delete,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RepaintBoundary(
              key: _cardKey,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: _pale,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: _line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.spa_outlined, color: _forest, size: 24),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '支线 · 生活的小小发现',
                            style: TextStyle(
                              color: _forest,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Text(
                      widget.entry.questTitle,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _date(widget.entry.createdAt),
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                    const SizedBox(height: 26),
                    Text(
                      widget.entry.text,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 1.9,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Divider(color: _line),
                    const SizedBox(height: 12),
                    const Text(
                      '不用远行，日常就有新的风景。',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _Panel(
              icon: Icons.lock_outline_rounded,
              title: '记录默认私密',
              text: '分享是你的主动选择。上方就是分享卡片内容，不含昵称和身份；请仍检查文字中的个人信息。',
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              _ErrorLabel(_error!),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _share,
              icon: _busy
                  ? const _Spinner()
                  : const Icon(Icons.ios_share_rounded),
              label: const Text('生成并分享图片卡片'),
            ),
            const SizedBox(height: 12),
            const Text(
              '打开系统分享面板后，由你选择接收方或保存位置。',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    ),
  );
}

class RulesPage extends StatelessWidget {
  const RulesPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(title: const Text('记录与媒体规则')),
    body: const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Panel(
              icon: Icons.construction_outlined,
              title: '这一版，先用文字留下发现',
              text: '当前可提交 1–300 个 Unicode 字符的文字。图片、录音、视频入口暂未开放；下面是后续接入时的设计限制，不代表现在已经支持上传。',
            ),
            SizedBox(height: 28),
            _Section(
              '计划中的图片规则',
              '最多 3 张，每张不超过 10 MB。JPG / JPEG、PNG、HEIC、WebP，仅静态图片。设备和服务均需能够实际解码。',
            ),
            _Section(
              '计划中的录音规则',
              '1 段，时长不超过 60 秒，同时文件不超过 10 MB。M4A、AAC、MP3、WAV。只记录自己有权录制的内容，避免收录他人的谈话。',
            ),
            _Section(
              '计划中的视频规则',
              '1 段，时长不超过 30 秒，同时文件不超过 50 MB。MP4、MOV，建议最高 1080p。容器格式符合不代表所有编码都能播放。',
            ),
            _Section(
              '任选一种，不增加负担',
              '未来一次记录可选一种媒体类别，不强制拍照、不做 AI 真实性核验。大小、格式、时长和解码能力必须由客户端及服务端共同检查，不能只看扩展名。',
            ),
            _Section(
              '隐私保护要随功能一起落地',
              '后续媒体处理需移除位置等元数据，只在使用时请求权限；人物、门牌和录音内容仍可能暴露隐私。权限拒绝、文件超限或上传失败时，应保留文字草稿。当前没有媒体处理或上传服务，不能视为已完成这些保护。',
            ),
          ],
        ),
      ),
    ),
  );
}

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key, required this.remote});
  final bool remote;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(title: const Text('隐私与内测说明')),
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
              title: remote ? '当前：连接服务的文字内测版' : '当前：单机文字内测版',
              text: remote
                  ? '账号及文字记录会发送到已配置的 API 服务。连接模式不代表服务已完成生产安全审计，请仅使用测试内容。'
                  : '账号、任务进度和文字记录保存在当前安装的应用数据中。没有云同步，昵称只在当前安装内检查重复。',
            ),
            const SizedBox(height: 28),
            const _Section(
              '只收集完成体验所需的信息',
              '使用昵称和密码，不收集手机号。身份必选，探索偏好可跳过，并可后续修改；身份仅帮助选择合适场景，不代表年龄验证，也不增加任务难度。暂不支持密码找回。',
            ),
            _Section(
              '数据存放与安全边界',
              remote
                  ? '私人记录通过配置的 API 保存，需要账号鉴权。本机可能仍保存会话信息和体验状态。当前版本不是端到端加密服务，不要记录密码、证件、健康等敏感资料。'
                  : '本地探索记录没有额外加密保护。Android 已禁用自动备份，但卸载、清除数据或更换手机仍可能丢失账号和记录。系统已解锁、被 root 或被他人接触的设备不在应用可保证的保护范围内。',
            ),
            const _Section(
              '不追踪位置，不索取无关权限',
              '当前不请求 GPS、摄像头、麦克风或相册权限，不记录行动轨迹。本版不支持媒体上传或定时通知；未来通知必须主动开启并选择时间。',
            ),
            const _Section(
              '默认私密，分享由你决定',
              '没有公开信息流，不自动公开完成记录。生成图片卡片前会要求确认，卡片不包含昵称和身份，但你写下的内容仍可能包含隐私。系统分享产生的文件或接收方副本，无法由本应用自动撤回。',
            ),
            const _Section(
              '删除与导出',
              '可在单条记录中主动生成并分享图片卡片，也可删除该记录；在账号设置中查看当前提供的导出、数据清除或账号删除操作。删除前请先保存需要保留的内容，不依赖应用提供数据恢复。',
            ),
            const _Section(
              '不以压力换取完成',
              '任务应轻量、低风险，不强制消费、社交或运动。每天一次换题额度与安全停止分开：任何时候不适合，都可以停止。没有强制连续签到，也没有本版惩罚。',
            ),
            const _Section(
              '内测不是生产服务承诺',
              '本版用于验证流程和感受，未上架，不代表已经部署公共服务或完成合规审查。图片/录音/视频、通知及正式账号恢复需后续实现并测试。请勿保存不可替代的资料。',
            ),
          ],
        ),
      ),
    ),
  );
}

class _CodePointLimit extends TextInputFormatter {
  const _CodePointLimit(this.maximum);
  final int maximum;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.text.runes.length <= maximum ? newValue : oldValue;
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
    height: 160,
    decoration: BoxDecoration(
      color: _pale,
      borderRadius: BorderRadius.circular(28),
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          right: 28,
          top: 20,
          child: Container(
            width: 58,
            height: 58,
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
          size: 88,
          color: _forest,
        ),
        Positioned(
          left: 20,
          bottom: 18,
          child: Text(
            '小小探索 · 不必远行',
            style: TextStyle(
              color: _forest.withValues(alpha: .65),
              fontSize: 11,
            ),
          ),
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
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _pale,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: _forest),
        const SizedBox(width: 10),
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
              const SizedBox(height: 6),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  color: _muted,
                  height: 1.65,
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

Future<bool> _confirm(
  BuildContext context,
  String title,
  String text,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(text, style: const TextStyle(height: 1.7)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
