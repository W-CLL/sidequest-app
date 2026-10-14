import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'domain.dart';
import 'media_widgets.dart';
import 'repository.dart';
import 'exit_guard_io.dart' if (dart.library.js_interop) 'exit_guard_web.dart' as exit_guard;
import 'voice.dart';

const _muted = Color(0xFF69756C);
const _forest = Color(0xFF234D3C);
const _ink = Color(0xFF203B31);
const _lime = Color(0xFFDFECAC);
const _pale = Color(0xFFEEF1E6);
String _errorText(Object error) => userMessageFor(error);
String _date(DateTime value) {
  final date = value.toLocal();
  return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
}

class RecordPage extends StatefulWidget {
  const RecordPage({
    super.key,
    required this.repository,
    required this.quest,
    required this.initialDraft,
    this.initialAttachments = const [],
    this.accountId,
    this.conflictDraftId,
    this.branchId,
  });
  final QuestRepository repository;
  final Quest quest;
  final String initialDraft;
  final List<MediaAttachment> initialAttachments;
  final String? accountId;
  final String? conflictDraftId;
  final String? branchId;
  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> with WidgetsBindingObserver {
  late final TextEditingController _text;
  late List<MediaAttachment> _attachments;
  String? _accountId, _error;
  String? _editorBranchId, _conflictDraftId, _contextNotice;
  bool _opening = false;
  late String _saveStatus = _autoSaveHint;
  Timer? _debounce;

  // 安卓/桌面草稿落在本机；网页版直接存服务端，文案随之区分。
  bool get _localDraft => !widget.repository.isWebClient;
  String get _autoSaveHint => _localDraft ? '停笔 1 秒后自动保存到本机' : '停笔 1 秒后自动保存';
  String get _savingLabel => _localDraft ? '正在保存到本机…' : '正在保存…';
  String get _savedLabel => _localDraft ? '草稿已存本机' : '草稿已保存';
  Future<bool>? _saving;
  int _generation = 0, _savedGeneration = 0;
  final _removedMedia = <String>{};
  bool _busy = false, _allowPop = false, _mediaBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 网页版：草稿还在保存时关闭/刷新页面，交给浏览器做通用离开确认（其他平台为空实现）。
    exit_guard.attachUnsavedDraftGuard(
      () => mounted && _editorReady && _generation != _savedGeneration,
    );
    _accountId = widget.accountId;
    _text = TextEditingController(
      text: widget.conflictDraftId == null ? '' : widget.initialDraft,
    )..addListener(_changed);
    _attachments = widget.conflictDraftId == null
        ? []
        : List.of(widget.initialAttachments);
    _conflictDraftId = widget.conflictDraftId;
    if (_conflictDraftId != null) _editorBranchId = widget.branchId;
    if (_conflictDraftId == null) {
      unawaited(_openEditor());
    } else if (_accountId == null) {
      widget.repository
          .load()
          .then((state) {
            if (mounted) setState(() => _accountId = state.profile?.id);
          })
          .catchError((Object error) {
            if (mounted) setState(() => _error = _errorText(error));
          });
    }
  }

  bool get _editorReady => _editorBranchId != null || _conflictDraftId != null;

  Future<void> _openEditor() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
      _saveStatus = '正在打开草稿…';
    });
    try {
      final editor = await widget.repository.openDraftEditor(widget.quest.id);
      if (!mounted) return;
      _text.text = editor.snapshot.draft;
      setState(() {
        _editorBranchId = editor.branchId;
        _accountId = editor.snapshot.profile?.id;
        _attachments = List.of(editor.snapshot.draftAttachments);
        _saveStatus = _autoSaveHint;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  bool _adoptConflict(AppSnapshot snapshot) {
    if (_conflictDraftId != null || _editorBranchId == null) return false;
    final draft = snapshot.conflictDrafts
        .where(
          (d) => d.branchId == _editorBranchId && d.questId == widget.quest.id,
        )
        .firstOrNull;
    if (draft == null) return false;
    _conflictDraftId = draft.id;
    if (mounted) {
      setState(
        () => _contextNotice = '当前进度已更新，这次内容已保留为冲突草稿。继续编辑或完成只保存这份记录，不改变当前活动。',
      );
    }
    return true;
  }

  void _editorMoved(DraftEditorMovedException error) {
    _adoptConflict(error.snapshot);
    _conflictDraftId = error.conflictDraftId;
    if (mounted) {
      setState(() {
        _error = null;
        _saveStatus = '冲突草稿已存本机';
        _contextNotice = '当前进度已更新，这次内容已保留为冲突草稿。继续编辑或完成只保存这份记录，不改变当前活动。';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _text.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        !_busy) {
      _debounce?.cancel();
      unawaited(_save());
    }
  }

  void _changed() {
    if (!_editorReady || _opening) return;
    _generation++;
    _debounce?.cancel();
    if (mounted) setState(() => _saveStatus = '尚未保存');
    if (!_busy) {
      _debounce = Timer(const Duration(seconds: 1), () => unawaited(_save()));
    }
  }

  Future<bool> _save({bool notify = false}) async {
    if (!_editorReady) return false;
    if (_saving != null) return _saving!;
    _debounce?.cancel();
    final future = _persist();
    _saving = future;
    final ok = await future;
    _saving = null;
    if (ok && notify && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$_savedLabel。')));
    }
    return ok;
  }

  Future<bool> _persist() async {
    try {
      while (true) {
        while (_generation != _savedGeneration) {
          final generation = _generation;
          final text = _text.text;
          final attachments = List<MediaAttachment>.of(_attachments);
          if (mounted) {
            setState(() {
              _saveStatus = _savingLabel;
              _error = null;
            });
          }
          if (_conflictDraftId case final id?) {
            await widget.repository.saveConflictDraft(
              id,
              text,
              attachments: attachments,
            );
          } else {
            try {
              final snapshot = await widget.repository.saveDraft(
                text,
                attachments: attachments,
                expectedBranchId: _editorBranchId,
                expectedQuestId: widget.quest.id,
              );
              _adoptConflict(snapshot);
            } on DraftEditorMovedException catch (error) {
              _editorMoved(error);
            }
          }
          _savedGeneration = generation;
        }
        await _discardRemovedMedia();
        if (_generation == _savedGeneration) break;
      }
      if (mounted) setState(() => _saveStatus = _savedLabel);
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _errorText(error);
          _saveStatus = '保存失败，请重试';
        });
      }
      return false;
    }
  }

  Future<void> _discardRemovedMedia() async {
    final retained = _attachments.map((m) => m.id).toSet();
    final unused = _removedMedia.difference(retained).toList();
    if (unused.isEmpty) return;
    try {
      await widget.repository.discardStagedMedia(unused);
      _removedMedia.removeAll(unused);
    } catch (_) {
      if (mounted) {
        setState(() => _error = _localDraft
            ? '内容已保存，移除附件的本机副本暂未清理。下次保存时重试。'
            : '内容已保存，移除的附件暂未清理，下次保存时重试。');
      }
    }
  }

  Future<void> _leave() async {
    if (_busy || _mediaBusy || _allowPop) return;
    setState(() => _busy = true);
    if (_editorReady && !await _save()) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _complete() async {
    if (_busy || _mediaBusy || !_editorReady) return;
    final text = _text.text.trim();
    if (text.isEmpty || text.runes.length > 500) {
      setState(() => _error = '请填写 1–500 个字的记录。');
      return;
    }
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_saving != null) await _saving;
      final snapshot = _conflictDraftId == null
          ? await widget.repository.complete(
              text,
              attachments: List.of(_attachments),
              expectedBranchId: _editorBranchId,
              expectedQuestId: widget.quest.id,
            )
          : await widget.repository.completeConflictDraft(
              _conflictDraftId!,
              text,
              attachments: List.of(_attachments),
            );
      if (_adoptConflict(snapshot)) {
        _savedGeneration = _generation;
        if (mounted) setState(() => _saveStatus = '冲突草稿已存本机');
        return;
      }
      await _discardRemovedMedia();
      if (!mounted) return;
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(snapshot);
    } on DraftEditorMovedException catch (error) {
      _savedGeneration = _generation;
      _editorMoved(error);
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
      if (!didPop) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('记录这次发现'),
        leading: IconButton(
          tooltip: '保存并返回',
          onPressed: _busy || _mediaBusy ? null : _leave,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('record-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          children: [
            Text(
              widget.quest.title,
              style: const TextStyle(color: _forest, fontSize: 13),
            ),
            const SizedBox(height: 10),
            _RecordSteps(quest: widget.quest),
            const SizedBox(height: 12),
            const Text(
              '这一刻，你发现了什么？',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text('一句话、几个词都可以。', style: TextStyle(color: _muted)),
            const SizedBox(height: 12),
            TextField(
              key: const Key('record-text-field'),
              controller: _text,
              readOnly: _busy || !_editorReady,
              minLines: 5,
              maxLines: 5,
              inputFormatters: [const CodePointLimit(500)],
              scrollPadding: const EdgeInsets.only(bottom: 180),
              decoration: const InputDecoration(
                hintText: '比如：窗边叶子的绿，比杯子上的更柔和。',
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _saveStatus,
                    key: const Key('draft-save-status'),
                    style: const TextStyle(fontSize: 12, color: _muted),
                  ),
                ),
                Text(
                  '${_text.text.runes.length} / 500',
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (_accountId != null && _editorReady)
              MediaComposer(
                repository: widget.repository,
                accountId: _accountId!,
                contextId: _editorBranchId != null
                    ? 'branch:$_editorBranchId:${widget.quest.id}'
                    : 'conflict:$_conflictDraftId',
                attachments: _attachments,
                enabled: !_busy,
                onBusyChanged: (busy) => setState(() => _mediaBusy = busy),
                onChanged: (media) {
                  final retained = media.map((m) => m.id).toSet();
                  _removedMedia.addAll(
                    _attachments
                        .where((m) => !retained.contains(m.id))
                        .map((m) => m.id),
                  );
                  setState(() => _attachments = media);
                  _changed();
                },
                onError: (error) => setState(() => _error = error),
              ),
            const SizedBox(height: 12),
            Text(
              widget.repository.isWebClient
                  ? '写下来，就留住了。只有你能看到。'
                  : '写下来，就留住了。稍后自动同步，只有你能看到。',
              style: const TextStyle(fontSize: 12, color: _muted, height: 1.5),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              ErrorNotice(_error!),
            ],
            if (_contextNotice != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _contextNotice!,
                  key: const Key('record-conflict-notice'),
                ),
              ),
            if (!_editorReady && !_opening)
              TextButton(
                key: const Key('record-open-retry'),
                onPressed: _openEditor,
                child: const Text('重新打开草稿'),
              ),
          ],
        ),
      ),
      bottomNavigationBar: EditorBottomBar(
        children: [
          OutlinedButton.icon(
            key: const Key('record-save-draft-action'),
            onPressed: _busy || !_editorReady
                ? null
                : () => _save(notify: true),
            icon: const Icon(Icons.bookmark_outline),
            label: const Text('保存草稿'),
          ),
          FilledButton.icon(
            key: const Key('record-complete-action'),
            onPressed: _busy || _mediaBusy || !_editorReady ? null : _complete,
            icon: const Icon(Icons.check),
            label: Text(_busy ? '正在保存…' : '完成并保存'),
          ),
        ],
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
  late JournalEntry _entry = widget.entry;
  bool _busy = false, _changed = false;
  String? _error;
  StreamSubscription<SyncSummary>? _updates;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _updates = widget.repository.syncUpdates.listen((_) {
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(const Duration(milliseconds: 250), () async {
        try {
          final state = await widget.repository.load();
          final current = state.entries
              .where((entry) => entry.id == _entry.id)
              .firstOrNull;
          if (mounted && current != null) setState(() => _entry = current);
        } catch (_) {
          /* Keep the visible entry when status refresh fails. */
        }
      });
    });
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    unawaited(_updates?.cancel());
    super.dispose();
  }

  Future<void> _edit() async {
    final result = await Navigator.of(context).push<JournalEntry>(
      MaterialPageRoute(
        builder: (_) =>
            EntryEditor(entry: _entry, repository: widget.repository),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _entry = result;
        _changed = true;
      });
    }
  }

  Future<void> _delete() async {
    if (!await confirmPrivateAction(
          context,
          '删除这条记录？',
          '删除后不能恢复。已分享出去的卡片和他人副本不会被撤回。',
          '删除记录',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.repository.deleteEntry(_entry.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    canPop: !_changed,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) {
        setState(() => _changed = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop(true);
        });
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('探索记录'),
        actions: [
          IconButton(
            key: const Key('entry-edit-action'),
            tooltip: '编辑记录',
            onPressed: _busy || _entry.syncStatus != 'saved' ? null : _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            key: const Key('entry-delete-action'),
            tooltip: '删除记录',
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text(
              _entry.questTitle,
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '${_date(_entry.createdAt)} · ${syncStatusLabel(_entry.syncStatus)}',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            SelectableText(
              _entry.text,
              style: const TextStyle(fontSize: 17, height: 1.7),
            ),
            if (_entry.attachments.isNotEmpty) ...[
              const SizedBox(height: 16),
              AttachmentList(
                attachments: _entry.attachments,
                repository: widget.repository,
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              '只有你能看到。编辑已同步的内容需要网络；分享前可以另选图片。',
              style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
            ),
            if (_entry.syncError != null) ErrorNotice(_entry.syncError!),
            if (_error != null) ErrorNotice(_error!),
          ],
        ),
      ),
      bottomNavigationBar: EditorBottomBar(
        children: [
          FilledButton.icon(
            key: const Key('entry-share-action'),
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ShareSelectionPage(
                        entry: _entry,
                        repository: widget.repository,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.ios_share),
            label: const Text('分享图片卡片'),
          ),
        ],
      ),
    ),
  );
}

class EntryEditor extends StatefulWidget {
  const EntryEditor({super.key, required this.entry, required this.repository});
  final JournalEntry entry;
  final QuestRepository repository;
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  late final TextEditingController _text = TextEditingController(
    text: widget.entry.text,
  );
  late List<MediaAttachment> _media = List.of(widget.entry.attachments);
  late final _originalMedia = widget.entry.attachments.map((m) => m.id).toSet();
  final _newMedia = <String>{};
  String? _accountId, _error;
  bool _busy = false, _allowPop = false, _mediaBusy = false;
  @override
  void initState() {
    super.initState();
    widget.repository
        .load()
        .then((state) {
          if (mounted) setState(() => _accountId = state.profile?.id);
        })
        .catchError((Object error) {
          if (mounted) setState(() => _error = _errorText(error));
        });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _text.text != widget.entry.text ||
      _media.map((e) => e.id).join(',') !=
          widget.entry.attachments.map((e) => e.id).join(',');
  void _mediaChanged(List<MediaAttachment> media) {
    final retained = media.map((m) => m.id).toSet();
    _newMedia.addAll(retained.difference(_originalMedia));
    setState(() => _media = media);
    unawaited(_discardNewMedia(_newMedia.difference(retained)));
  }

  Future<bool> _discardNewMedia(Set<String> ids) async {
    if (ids.isEmpty) return true;
    try {
      await widget.repository.discardStagedMedia(ids.toList());
      _newMedia.removeAll(ids);
      return true;
    } catch (_) {
      if (mounted) setState(() => _error = '新增附件暂未清理，请重试。原记录未变更。');
      return false;
    }
  }

  Future<void> _leave() async {
    if (_busy || _mediaBusy) return;
    if (_dirty &&
        !await confirmPrivateAction(
          context,
          '放弃这次修改？',
          '原记录和原附件保持不变。',
          '放弃修改',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    if (!await _discardNewMedia(Set.of(_newMedia))) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_busy || _mediaBusy) return;
    if (_text.text.trim().isEmpty) {
      setState(() => _error = '请填写记录正文。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await widget.repository.updateEntry(
        widget.entry.id,
        _text.text.trim(),
        _media,
        widget.entry.revision,
      );
      final matches = snapshot.entries.where((e) => e.id == widget.entry.id);
      final entry = matches.isNotEmpty
          ? matches.first
          : JournalEntry(
              id: widget.entry.id,
              questId: widget.entry.questId,
              questTitle: widget.entry.questTitle,
              text: _text.text.trim(),
              createdAt: widget.entry.createdAt,
              updatedAt: DateTime.now(),
              revision: widget.entry.revision + 1,
              attachments: List.of(_media),
            );
      _newMedia.removeAll(_media.map((m) => m.id));
      await _discardNewMedia(Set.of(_newMedia));
      if (!mounted) return;
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(entry);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<JournalEntry>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('编辑记录'),
        leading: IconButton(
          key: const Key('entry-editor-back'),
          tooltip: '返回',
          onPressed: _busy || _mediaBusy ? null : _leave,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.entry.questTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('entry-edit-text'),
              controller: _text,
              readOnly: _busy,
              minLines: 5,
              maxLines: 8,
              inputFormatters: [const CodePointLimit(500)],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '记录正文'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${_text.text.runes.length} / 500'),
            ),
            if (_accountId != null)
              MediaComposer(
                repository: widget.repository,
                accountId: _accountId!,
                contextId: 'entry:${widget.entry.id}:${widget.entry.revision}',
                attachments: _media,
                enabled: !_busy,
                onBusyChanged: (busy) => setState(() => _mediaBusy = busy),
                onChanged: _mediaChanged,
                onError: (error) => setState(() => _error = error),
              ),
            const SizedBox(height: 12),
            const Text(
              '保存修改需要联网。保存成功前，移除附件不会删除原记录中的媒体。',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            if (_error != null) ErrorNotice(_error!),
          ],
        ),
      ),
      bottomNavigationBar: EditorBottomBar(
        children: [
          FilledButton(
            key: const Key('entry-save-edit'),
            onPressed: _busy || _mediaBusy ? null : _save,
            child: Text(_busy ? '正在保存…' : '保存修改'),
          ),
        ],
      ),
    ),
  );
}

class ShareSelectionPage extends StatefulWidget {
  const ShareSelectionPage({
    super.key,
    required this.entry,
    required this.repository,
  });
  final JournalEntry entry;
  final QuestRepository repository;
  @override
  State<ShareSelectionPage> createState() => _ShareSelectionPageState();
}

class _ShareSelectionPageState extends State<ShareSelectionPage> {
  final _selected = <String>{};
  @override
  Widget build(BuildContext context) {
    final images = widget.entry.attachments
        .where((m) => m.kind == MediaKind.image)
        .take(5)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('选择分享内容')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '默认只分享文字',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text('可选择 0–5 张图片。语音、视频、昵称与身份不会放入卡片。请检查正文和图片中的隐私。'),
            const SizedBox(height: 16),
            for (final media in images)
              CheckboxListTile(
                key: ValueKey('share-select-${media.id}'),
                value: _selected.contains(media.id),
                onChanged: (checked) => setState(() {
                  if (checked == true) {
                    _selected.add(media.id);
                  } else {
                    _selected.remove(media.id);
                  }
                }),
                title: Text('图片 ${images.indexOf(media) + 1}'),
                secondary: SizedBox(
                  width: 56,
                  height: 56,
                  child: PrivateMediaImage(
                    media: media,
                    repository: widget.repository,
                  ),
                ),
              ),
            Text(
              '已选 ${_selected.length} 张图片',
              key: const Key('share-selected-count'),
            ),
          ],
        ),
      ),
      bottomNavigationBar: EditorBottomBar(
        children: [
          FilledButton(
            key: const Key('share-preview-action'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SharePreviewPage(
                  entry: widget.entry,
                  repository: widget.repository,
                  images: images
                      .where((m) => _selected.contains(m.id))
                      .toList(),
                ),
              ),
            ),
            child: const Text('预览分享卡片'),
          ),
        ],
      ),
    );
  }
}

class SharePreviewPage extends StatefulWidget {
  const SharePreviewPage({
    super.key,
    required this.entry,
    required this.repository,
    required this.images,
  });
  final JournalEntry entry;
  final QuestRepository repository;
  final List<MediaAttachment> images;
  @override
  State<SharePreviewPage> createState() => _SharePreviewPageState();
}

class _SharePreviewPageState extends State<SharePreviewPage> {
  final _cardKey = GlobalKey();
  final _loaded = <String>{};
  bool _busy = false;
  String? _error;
  Future<void> _share() async {
    if (!await confirmPrivateAction(
          context,
          '分享这张卡片？',
          '接收方可以保存和转发。请确认文字及所选图片中没有你不想公开的信息。',
          '生成并分享',
        ) ||
        !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    ui.Image? image;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw const QuestException('卡片生成失败，请重试。');
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes.buffer.asUint8List(),
              mimeType: 'image/png',
              name: 'sidequest-card.png',
            ),
          ],
          fileNameOverrides: const ['sidequest-card.png'],
          title: '一次小发现',
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '分享未完成，原记录未受影响。');
    } finally {
      image?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('分享卡片预览')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            RepaintBoundary(
              key: _cardKey,
              child: Container(
                key: const Key('share-card-content'),
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                color: const Color(0xFFEEF1E6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '支线 · 生活里的小发现',
                      style: TextStyle(color: _forest, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.entry.questTitle,
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _date(widget.entry.createdAt),
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.entry.text,
                      style: const TextStyle(fontSize: 17, height: 1.7),
                    ),
                    for (final media in widget.images)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SizedBox(
                          height: 180,
                          width: double.infinity,
                          child: PrivateMediaImage(
                            key: ValueKey('share-image-${media.id}'),
                            media: media,
                            repository: widget.repository,
                            thumbnail: false,
                            fit: BoxFit.contain,
                            onLoaded: () {
                              if (mounted) {
                                setState(() => _loaded.add(media.id));
                              }
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_loaded.length < widget.images.length)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('图片加载完成后可分享；无法加载时请返回重新选择。'),
              ),
            if (_error != null) ErrorNotice(_error!),
          ],
        ),
      ),
    ),
    bottomNavigationBar: EditorBottomBar(
      children: [
        FilledButton.icon(
          key: const Key('share-confirm-action'),
          onPressed: _busy || _loaded.length != widget.images.length
              ? null
              : _share,
          icon: const Icon(Icons.ios_share),
          label: Text(_busy ? '正在生成…' : '确认并分享'),
        ),
      ],
    ),
  );
}

class SyncStatusPage extends StatefulWidget {
  const SyncStatusPage({super.key, required this.repository, this.onLogin});
  final QuestRepository repository;
  final Future<void> Function()? onLogin;
  @override
  State<SyncStatusPage> createState() => _SyncStatusPageState();
}

class _SyncStatusPageState extends State<SyncStatusPage> {
  SyncSummary? _summary;
  AppSnapshot? _state;
  StreamSubscription<SyncSummary>? _subscription;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _subscription = widget.repository.syncUpdates.listen((summary) {
      if (mounted) setState(() => _summary = summary);
      unawaited(_refreshState());
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _refreshState() async {
    try {
      final state = await widget.repository.load();
      if (mounted) setState(() => _state = state);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _refresh() async {
    try {
      final summary = await widget.repository.getSyncSummary();
      if (mounted) setState(() => _summary = summary);
      await _refreshState();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _upload() async {
    if (!await confirmPrivateAction(
          context,
          '现在同步？',
          '这次会用流量，只同步确认的这一批；之后仍在无线网时自动同步。',
          '同步',
        ) ||
        !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.syncNow(allowMetered: true);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resume(ConflictDraft draft) async {
    try {
      final state = await widget.repository.resumeConflictDraft(draft.id);
      if (!mounted) return;
      await Navigator.of(context).push<AppSnapshot>(
        MaterialPageRoute(
          builder: (_) => RecordPage(
            repository: widget.repository,
            quest: questById(draft.questId),
            initialDraft: state.draft,
            initialAttachments: state.draftAttachments,
            accountId: state.profile?.id,
            conflictDraftId: draft.id,
            branchId: draft.branchId,
          ),
        ),
      );
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _removePendingAttachments(JournalEntry entry) async {
    if (_busy ||
        !await confirmPrivateAction(
          context,
          '移除附件，仅同步文字？',
          '这条还没同步的记录会去掉图片、视频和语音，只留文字。已有的记录不受影响；去掉的附件无法恢复。',
          '移除附件并重试',
        ) ||
        !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.removePendingAttachments(entry.id);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard(ConflictDraft draft) async {
    if (!await confirmPrivateAction(
      context,
      '删除这份冲突草稿？',
      '只删除这份留在手机里的草稿，不影响已完成的记录和别的设备。',
      '删除草稿',
    )) {
      return;
    }
    try {
      await widget.repository.discardConflictDraft(draft.id);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('同步')),
    body: SafeArea(
      child: ListView(
        key: const Key('sync-status-scroll'),
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '稍后自动同步',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            '还没同步的内容先存在手机里。卸载或清除数据前，请确认全部同步完成。',
            style: TextStyle(color: _muted, height: 1.5),
          ),
          const SizedBox(height: 16),
          Text(
            '待同步 ${_summary?.pending ?? 0} · 同步中 ${_summary?.uploading ?? 0} · 失败 ${_summary?.failed ?? 0}',
            key: const Key('sync-summary'),
          ),
          if (_summary?.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_summary!.message!),
            ),
          if (_summary?.requiresLogin == true) ...[
            const SizedBox(height: 12),
            const Text('登录过期了，内容都还在。登录原账号后继续同步。'),
            OutlinedButton(
              key: const Key('sync-login-action'),
              onPressed: _busy || widget.onLogin == null
                  ? null
                  : () async {
                      await widget.onLogin!();
                      await _refresh();
                    },
              child: const Text('重新登录'),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('sync-upload-now'),
            onPressed: _busy || _summary?.requiresLogin == true
                ? null
                : _upload,
            child: Text(_busy ? '正在同步…' : '同步'),
          ),
          for (final entry
              in _state?.entries.where((e) => e.syncStatus != 'saved') ??
                  <JournalEntry>[]) ...[
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(entry.questTitle),
              subtitle: Text(
                entry.syncError ?? syncStatusLabel(entry.syncStatus),
              ),
              leading: Icon(
                entry.syncStatus == 'failed'
                    ? Icons.error_outline
                    : Icons.cloud_upload_outlined,
              ),
            ),
            if (entry.syncStatus == 'failed' && entry.attachments.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: ValueKey('sync-text-only-${entry.id}'),
                  onPressed: _busy || _summary?.requiresLogin == true
                      ? null
                      : () => _removePendingAttachments(entry),
                  child: const Text('移除附件，仅同步文字'),
                ),
              ),
          ],
          if (_state?.conflictDrafts.isNotEmpty == true) ...[
            const SizedBox(height: 20),
            const Text(
              '保留的冲突草稿',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
            const Text(
              '其他设备的进度已变化。这些草稿没有覆盖云端，你可以继续记录或删除。',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
            for (final draft in _state!.conflictDrafts)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft.text.isEmpty
                          ? '含 ${draft.attachments.length} 个附件的草稿'
                          : draft.text,
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        TextButton(
                          key: ValueKey('conflict-resume-${draft.id}'),
                          onPressed: _busy ? null : () => _resume(draft),
                          child: const Text('继续记录'),
                        ),
                        TextButton(
                          key: ValueKey('conflict-delete-${draft.id}'),
                          onPressed: _busy ? null : () => _discard(draft),
                          child: const Text('删除草稿'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
          if (_error != null) ErrorNotice(_error!),
        ],
      ),
    ),
  );
}

/// 记录页内的探索参考：与「探索详情」同一份步骤，默认展开、可折叠。
class _RecordSteps extends StatefulWidget {
  const _RecordSteps({required this.quest});
  final Quest quest;
  @override
  State<_RecordSteps> createState() => _RecordStepsState();
}

class _RecordStepsState extends State<_RecordSteps> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final steps = widget.quest.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    return Material(
      color: _pale,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const Key('record-steps-toggle'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  const Icon(Icons.checklist_rounded, size: 18, color: _forest),
                  const SizedBox(width: 8),
                  const Text(
                    '探索参考',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _open ? '收起' : '展开',
                    style: const TextStyle(fontSize: 12, color: _muted),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: _muted,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                key: const Key('record-steps-list'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < steps.length; index++)
                    Padding(
                      padding: EdgeInsets.only(top: index == 0 ? 2 : 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 11,
                            backgroundColor: _lime,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _forest,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              steps[index],
                              style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.55,
                                color: _ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class EditorBottomBar extends StatelessWidget {
  const EditorBottomBar({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 150),
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (children.length == 1) return children.first;
          if (constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.4) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                children.first,
                const SizedBox(height: 8),
                children.last,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: children.first),
              const SizedBox(width: 12),
              Expanded(child: children.last),
            ],
          );
        },
      ),
    ),
  );
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Semantics(
      liveRegion: true,
      child: Text(
        message,
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          height: 1.5,
        ),
      ),
    ),
  );
}

class CodePointLimit extends TextInputFormatter {
  const CodePointLimit(this.maximum);
  final int maximum;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.text.runes.length <= maximum ? newValue : oldValue;
}

Future<bool> confirmPrivateAction(
  BuildContext context,
  String title,
  String message,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
