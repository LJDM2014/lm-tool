import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/pdf_core.dart';
import '../services/platform_io.dart';
import '../widgets/common.dart';

/// 可视化页面编辑器：缩略图浏览，旋转/删除/移动/擦除/插入页面，
/// 支持水印与元数据，保存为新 PDF。
class PageEditorPage extends StatefulWidget {
  const PageEditorPage({super.key});

  @override
  State<PageEditorPage> createState() => _PageEditorPageState();
}

class _PageEditorPageState extends State<PageEditorPage> {
  PickedDoc? _doc;
  PdfEditSession? _session;
  int _pageCount = 0;

  /// 缩略图 PNG 字节（按页索引存储；主文档 0..n-1，外部页 n..）。
  final _thumbs = <int, Uint8List>{};
  int _loadedThumbs = 0;
  StreamSubscription<RenderedPage>? _thumbSub;

  /// 当前页序（页索引；外部页索引 ≥ 主文档页数）。
  List<int> _order = const [];

  /// 页索引 → 累计旋转角度。
  final _rotations = <int, int>{};

  /// 擦除模式与归一化擦除区域（左上原点，0-1）。
  bool _eraseMode = false;
  final _erases = <int, List<Rect>>{};

  /// 待追加的外部 PDF（当前仅支持一个来源）。
  PickedDoc? _mergeSource;
  int _appendedCount = 0;

  // 高级选项：元数据与水印。
  final _titleCtrl = TextEditingController();
  final _authorCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _keywordsCtrl = TextEditingController();
  bool _watermarkEnabled = false;
  final _watermarkCtrl = TextEditingController();
  bool _watermarkTiled = false;
  double _watermarkOpacity = 0.3;

  bool _saving = false;
  PdfJob<void>? _job;
  List<PdfOutput>? _results;
  String? _message;

  bool get _busy => _saving;

  bool get _hasMetadata =>
      _titleCtrl.text.isNotEmpty ||
      _authorCtrl.text.isNotEmpty ||
      _subjectCtrl.text.isNotEmpty ||
      _keywordsCtrl.text.isNotEmpty;

  bool get _hasWatermark =>
      _watermarkEnabled && _watermarkCtrl.text.trim().isNotEmpty;

  bool get _hasEdits =>
      _rotations.isNotEmpty ||
      _erases.isNotEmpty ||
      _mergeSource != null ||
      _hasMetadata ||
      _hasWatermark ||
      (_session != null &&
          (_order.length != _session!.pageCount + _appendedCount ||
              !_isIdentity(_order)));

  static bool _isIdentity(List<int> order) {
    for (var i = 0; i < order.length; i++) {
      if (order[i] != i) return false;
    }
    return true;
  }

  Future<void> _pickFile() async {
    final docs = await pickDocs(
      extensions: const ['pdf'],
    );
    if (docs.isEmpty) return;
    await _useDoc(docs.first);
  }

  Future<void> _useDoc(PickedDoc doc) async {
    await _closeSession();
    setState(() {
      _doc = doc;
      _thumbs.clear();
      _loadedThumbs = 0;
      _pageCount = 0;
      _order = const [];
      _rotations.clear();
      _erases.clear();
      _eraseMode = false;
      _mergeSource = null;
      _appendedCount = 0;
      _results = null;
      _message = null;
      _saving = false;
    });
    try {
      final session =
          await PdfCore.instance.openEditor(await pdfInputOf(doc));
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _pageCount = session.pageCount;
        _order = [for (var i = 0; i < session.pageCount; i++) i];
      });
      _loadThumbnails(session);
    } catch (_) {
      // 需要密码解锁。
      final pwd = await _promptPassword();
      if (pwd == null || !mounted) {
        if (mounted) setState(() => _message = '已取消');
        return;
      }
      try {
        final session = await PdfCore.instance
            .openEditor(await pdfInputOf(doc), password: pwd);
        if (!mounted) {
          await session.dispose();
          return;
        }
        setState(() {
          _session = session;
          _pageCount = session.pageCount;
          _order = [for (var i = 0; i < session.pageCount; i++) i];
        });
        _loadThumbnails(session);
      } catch (e) {
        if (mounted) setState(() => _message = '无法打开该文件：$e');
      }
    }
  }

  void _loadThumbnails(PdfEditSession session) {
    _thumbSub?.cancel();
    _thumbSub = session.thumbnails().listen(
      (page) {
        if (!mounted || session != _session) return;
        final index = _loadedThumbs++;
        setState(() => _thumbs[index] = page.data);
      },
      onError: (Object e) {
        if (mounted) setState(() => _message = '缩略图加载失败：$e');
      },
    );
  }

  Future<String?> _promptPassword() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('该文件已加密'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '打开密码',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text),
            child: const Text('解锁'),
          ),
        ],
      ),
    );
  }

  void _rotate(int index) {
    setState(() {
      _rotations[index] = ((_rotations[index] ?? 0) + 90) % 360;
    });
  }

  void _rotateAll() {
    setState(() {
      for (final idx in _order) {
        _rotations[idx] = ((_rotations[idx] ?? 0) + 90) % 360;
      }
    });
  }

  void _deleteAt(int position) {
    setState(() {
      _order.removeAt(position);
      if (_order.isEmpty) _message = '已删除全部页面，保存前请先撤销或重置';
    });
  }

  void _move(int position, int delta) {
    final target = position + delta;
    if (target < 0 || target >= _order.length) return;
    setState(() {
      final page = _order.removeAt(position);
      _order.insert(target, page);
    });
  }

  void _toggleEraseMode() {
    setState(() {
      _eraseMode = !_eraseMode;
      if (_eraseMode) _message = '擦除模式：在页面缩略图上拖动框选要抹掉的内容';
    });
  }

  void _commitErase(int index, Rect normalized) {
    setState(() {
      final list = _erases.putIfAbsent(index, () => []);
      list.add(normalized);
    });
  }

  void _clearErases() {
    setState(() => _erases.clear());
  }

  /// 插入其他 PDF 的全部页面（追加到当前末尾，可再移动/删除）。
  Future<void> _insertPdf() async {
    final session = _session;
    if (session == null || _busy) return;
    final docs = await pickDocs(
      extensions: const ['pdf'],
    );
    if (docs.isEmpty) return;
    final source = docs.first;
    if (_mergeSource != null &&
        (_mergeSource!.name != source.name ||
            _mergeSource!.size != source.size)) {
      setState(() => _message = '当前仅支持插入一个外部 PDF，如需更换请先重置');
      return;
    }
    setState(() => _message = '正在读取外部 PDF…');
    try {
      final preview = await session.loadInsertPreview(await pdfInputOf(source));
      if (!mounted) return;
      final base = session.pageCount + _appendedCount;
      setState(() {
        _mergeSource = source;
        for (var k = 0; k < preview.pageCount; k++) {
          _order.add(base + k);
          _thumbs[base + k] = preview.thumbs[k];
        }
        _appendedCount += preview.pageCount;
        _message = null;
      });
    } catch (e) {
      if (mounted) setState(() => _message = '读取外部 PDF 失败：$e');
    }
  }

  void _reset() {
    setState(() {
      _rotations.clear();
      _erases.clear();
      _eraseMode = false;
      _order = [for (var i = 0; i < _pageCount; i++) i];
      // 移除外部页缩略图。
      _thumbs.removeWhere((k, _) => k >= _pageCount);
      _mergeSource = null;
      _appendedCount = 0;
      _message = null;
    });
  }

  Future<void> _save() async {
    if (!outputReady) {
      setState(() => _message = '请先选择输出目录');
      return;
    }
    if (_order.isEmpty) return;
    setState(() {
      _saving = true;
      _results = null;
      _message = '正在保存…';
    });
    try {
      final session = _session!;
      final job = await session.save(
        order: List.of(_order),
        rotations: Map.of(_rotations),
        mergeSource:
            _mergeSource == null ? null : await pdfInputOf(_mergeSource!),
        erases: _erases.isEmpty
            ? null
            : {
                for (final e in _erases.entries)
                  e.key: List.of(e.value),
              },
        watermarkText: _hasWatermark ? _watermarkCtrl.text : null,
        watermarkPosition: _hasWatermark
            ? (_watermarkTiled
                ? const PdfWatermarkPosition.tiled(columns: 3, rows: 3)
                : const PdfWatermarkPosition.center())
            : null,
        watermarkStyle: _hasWatermark
            ? PdfWatermarkStyle(opacity: _watermarkOpacity)
            : null,
        title: _titleCtrl.text.isEmpty ? null : _titleCtrl.text,
        author: _authorCtrl.text.isEmpty ? null : _authorCtrl.text,
        subject: _subjectCtrl.text.isEmpty ? null : _subjectCtrl.text,
        keywords: _keywordsCtrl.text.isEmpty ? null : _keywordsCtrl.text,
      );
      setState(() => _job = job);
      await job.done;
      await saveOutputs(job.outputs);
      if (mounted) {
        setState(() {
          _results = job.outputs;
          _message = null;
        });
      }
    } on PdfCancelled {
      if (mounted) setState(() => _message = '已取消');
    } catch (e) {
      if (mounted) setState(() => _message = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _closeSession() async {
    _thumbSub?.cancel();
    _thumbSub = null;
    await _session?.dispose();
    _session = null;
    _rotations.clear();
    _erases.clear();
  }

  @override
  void dispose() {
    _thumbSub?.cancel();
    _session?.dispose();
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    _subjectCtrl.dispose();
    _keywordsCtrl.dispose();
    _watermarkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PdfDropZone(
      onDocsDropped: (files) {
        if (files.isNotEmpty && !_busy) _useDoc(files.first);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: '1 · 选择 PDF 文件',
            child: Column(
              children: [
                if (_doc == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '尚未选择文件（可拖入）',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  )
                else
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.picture_as_pdf_outlined),
                    title: Text(
                      _doc!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _session == null
                          ? '打开中…'
                          : '共 $_pageCount 页'
                              '${_appendedCount > 0 ? ' · 已插入 $_appendedCount 页' : ''}'
                              ' · ${sizeLabel(_doc!.size)}',
                    ),
                    trailing: IconButton(
                      onPressed: _busy ? null : _pickFile,
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: '重新选择',
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickFile,
                  icon: const Icon(Icons.add),
                  label: const Text('选择文件'),
                ),
              ],
            ),
          ),
          const SectionCard(title: '2 · 输出目录', child: OutputDirPicker()),
          if (_session != null)
            SectionCard(
              title: '3 · 页面编辑',
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: _busy ? null : _insertPdf,
                    icon: const Icon(Icons.add_box_outlined, size: 16),
                    label: const Text('插入 PDF'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _toggleEraseMode,
                    icon: Icon(
                      _eraseMode ? Icons.close : Icons.cleaning_services_outlined,
                      size: 16,
                    ),
                    label: Text(_eraseMode ? '退出擦除' : '擦除模式'),
                  ),
                  TextButton(
                    onPressed: _busy || _rotations.isEmpty ? null : _rotateAll,
                    child: const Text('全部旋转'),
                  ),
                  TextButton(
                    onPressed: _busy || !_hasEdits ? null : _reset,
                    child: const Text('重置'),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_eraseMode)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '在缩略图上拖动框选要抹掉的区域（仅支持未旋转的页面）',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          if (_erases.isNotEmpty)
                            TextButton(
                              onPressed: _busy ? null : _clearErases,
                              child: const Text('清除擦除'),
                            ),
                        ],
                      ),
                    ),
                  if (_loadedThumbs < _pageCount)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '缩略图加载中… $_loadedThumbs / $_pageCount',
                        style: TextStyle(color: theme.hintColor),
                      ),
                    ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = (constraints.maxWidth / 150)
                          .floor()
                          .clamp(2, 6);
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          childAspectRatio: 0.78,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: _order.length,
                        itemBuilder: (context, position) {
                          final index = _order[position];
                          final isExternal = index >= _pageCount;
                          return _PageCell(
                            label: isExternal ? '外部 ${(index - _pageCount) + 1}' : '第 ${index + 1} 页',
                            bytes: _thumbs[index],
                            quarterTurns:
                                ((_rotations[index] ?? 0) ~/ 90) % 4,
                            busy: _busy,
                            eraseMode: _eraseMode && !isExternal,
                            erases: _erases[index] ?? const [],
                            onRotate: () => _rotate(index),
                            onDelete: () => _deleteAt(position),
                            onMoveLeft: position == 0
                                ? null
                                : () => _move(position, -1),
                            onMoveRight: position == _order.length - 1
                                ? null
                                : () => _move(position, 1),
                            onEraseCommit: (rect) => _commitErase(index, rect),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          if (_session != null)
            SectionCard(
              title: '4 · 高级选项（元数据 / 水印）',
              child: Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(
                    '元数据、水印',
                    style: theme.textTheme.bodyMedium,
                  ),
                  children: [
                    TextField(
                      controller: _titleCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '标题',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _authorCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '作者',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _subjectCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '主题',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _keywordsCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '关键词（逗号分隔）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const Divider(height: 24),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _watermarkEnabled,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _watermarkEnabled = v),
                      title: const Text('添加文字水印（应用到全部页）'),
                    ),
                    if (_watermarkEnabled) ...[
                      TextField(
                        controller: _watermarkCtrl,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: '水印文字',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.image_outlined, size: 16),
                            label: Text('居中'),
                          ),
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.grid_on_outlined, size: 16),
                            label: Text('平铺'),
                          ),
                        ],
                        selected: {_watermarkTiled},
                        onSelectionChanged: _busy
                            ? null
                            : (s) =>
                                setState(() => _watermarkTiled = s.first),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text('透明度'),
                          Expanded(
                            child: Slider(
                              value: _watermarkOpacity,
                              min: 0.1,
                              max: 0.9,
                              divisions: 8,
                              label: _watermarkOpacity
                                  .toStringAsFixed(1),
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(
                                      () => _watermarkOpacity = v),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          SectionCard(
            title: '5 · 保存',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          _session != null && !_busy && _order.isNotEmpty
                              ? _save
                              : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(_busy
                          ? '保存中…'
                          : '保存为新 PDF（${_order.length} 页）'),
                    ),
                    if (_busy)
                      OutlinedButton.icon(
                        onPressed: () => _job?.cancel(),
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('取消'),
                      ),
                    if (_session != null &&
                        !_busy &&
                        !_hasEdits &&
                        _results == null)
                      Text(
                        '尚未做任何修改',
                        style: TextStyle(color: theme.hintColor),
                      ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  JobProgressBar(
                    status: _message!,
                    onCancel: () => _job?.cancel(),
                  ),
                ],
                if (!_busy && _message != null && _results == null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _message!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                if (_results != null) ...[
                  const SizedBox(height: 16),
                  ResultView(outputs: _results!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 缩略图单元：页码徽标 + 旋转显示 + 擦除框选 + 单元操作按钮。
class _PageCell extends StatefulWidget {
  const _PageCell({
    required this.label,
    required this.bytes,
    required this.quarterTurns,
    required this.busy,
    required this.eraseMode,
    required this.erases,
    required this.onRotate,
    required this.onDelete,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onEraseCommit,
  });

  final String label;
  final Uint8List? bytes;
  final int quarterTurns;
  final bool busy;
  final bool eraseMode;
  final List<Rect> erases;
  final VoidCallback onRotate;
  final VoidCallback onDelete;
  final VoidCallback? onMoveLeft;
  final VoidCallback? onMoveRight;
  final ValueChanged<Rect> onEraseCommit;

  @override
  State<_PageCell> createState() => _PageCellState();
}

class _PageCellState extends State<_PageCell> {
  Rect? _active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canErase = widget.eraseMode && widget.quarterTurns % 4 == 0;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: canErase ? theme.colorScheme.primary : theme.dividerColor,
          width: canErase ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.bytes == null)
                  const CircularProgressIndicator(strokeWidth: 2)
                else
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: RotatedBox(
                      quarterTurns: widget.quarterTurns,
                      child: Image.memory(
                        widget.bytes!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                // 已提交的擦除区域。
                for (final rect in widget.erases)
                  Positioned.fromRelativeRect(
                    rect: RelativeRect.fromLTRB(
                      rect.left,
                      rect.top,
                      1 - rect.right,
                      1 - rect.bottom,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.35),
                        border: Border.all(color: Colors.red, width: 1.5),
                      ),
                    ),
                  ),
                // 拖动中的区域。
                if (_active != null)
                  Positioned.fromRelativeRect(
                    rect: RelativeRect.fromLTRB(
                      _active!.left,
                      _active!.top,
                      1 - _active!.right,
                      1 - _active!.bottom,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.2),
                        border: Border.all(
                          color: Colors.red,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                // 擦除手势层（仅未旋转页面）。
                if (canErase)
                  Positioned.fill(
                    child: Builder(
                      builder: (gestureContext) => GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanStart: (d) => setState(() => _active =
                            Rect.fromPoints(
                              _norm(d.localPosition, gestureContext),
                              _norm(d.localPosition, gestureContext),
                            )),
                        onPanUpdate: (d) => setState(() {
                          final end = _norm(d.localPosition, gestureContext);
                          final start = _active!.topLeft;
                          _active = Rect.fromPoints(start, end);
                        }),
                        onPanEnd: (_) {
                          final rect = _active;
                          setState(() => _active = null);
                          if (rect == null) return;
                          // 规范化为左上原点，并过滤过小（误触）的框选。
                          final normalized = Rect.fromLTRB(
                            math.min(rect.left, rect.right),
                            math.min(rect.top, rect.bottom),
                            math.max(rect.left, rect.right),
                            math.max(rect.top, rect.bottom),
                          );
                          if (normalized.width > 0.02 &&
                              normalized.height > 0.02) {
                            widget.onEraseCommit(normalized);
                          }
                        },
                      ),
                    ),
                  ),
                Positioned(
                  left: 4,
                  top: 4,
                  child: Chip(
                    label: Text(widget.label),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                    labelStyle: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: widget.busy ? null : widget.onMoveLeft,
                icon: const Icon(Icons.arrow_back_ios_new, size: 14),
                tooltip: '前移',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: widget.busy ? null : widget.onRotate,
                icon: const Icon(Icons.rotate_right, size: 18),
                tooltip: '旋转 90°',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: widget.busy ? null : widget.onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '删除此页',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: widget.busy ? null : widget.onMoveRight,
                icon: const Icon(Icons.arrow_forward_ios, size: 14),
                tooltip: '后移',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 把单元内局部坐标换算为 0-1 归一化坐标（左上原点）。
  Offset _norm(Offset local, BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final size = box.size;
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }
}
