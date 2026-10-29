import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/pdf_core.dart';
import '../services/platform_io.dart';
import '../services/task_queue.dart';
import '../widgets/common.dart';

/// 批量压缩 PDF：多选/拖入文件，按队列逐个压缩，展示逐项与总体前后对比。
class CompressPage extends StatefulWidget {
  const CompressPage({super.key});

  @override
  State<CompressPage> createState() => _CompressPageState();
}

class _Preset {
  const _Preset(this.label, this.description, this.policy);

  final String label;
  final String description;
  final PdfImagePolicy policy;
}

class _CompressPageState extends State<CompressPage> {
  // 说明：引擎默认 recompressJpeg=false、minSavings=0.10、
  // downsampleThreshold=1.5，对图片已是 JPEG 的 PDF（照片/扫描件）
  // 几乎不产生任何缩减。这里对"均衡/极限"档显式开启重编码并收紧阈值。
  static const _presets = [
    _Preset('无损优化', '不降低画质，仅重排与无损重编码', PdfImagePolicy.lossless),
    _Preset(
      '高清打印',
      '300 ppi · JPEG 85，适合打印，不重编码已有图片',
      PdfImagePolicy(
        colorPpi: 300,
        grayPpi: 300,
        monoPpi: 1200,
        jpegQuality: 85,
        chromaSubsampling: PdfChromaSubsampling.full,
      ),
    ),
    _Preset(
      '均衡（推荐）',
      '150 ppi · JPEG 75，重编码已有图片，屏幕阅读',
      PdfImagePolicy(
        colorPpi: 150,
        grayPpi: 150,
        monoPpi: 300,
        jpegQuality: 75,
        convertCmykToRgb: true,
        recompressJpeg: true,
        minSavings: 0.05,
        downsampleThreshold: 1.2,
      ),
    ),
    _Preset(
      '极限压缩',
      '72 ppi · JPEG 60，最大限度减小体积',
      PdfImagePolicy(
        colorPpi: 72,
        grayPpi: 72,
        monoPpi: 300,
        jpegQuality: 60,
        convertCmykToRgb: true,
        recompressJpeg: true,
        minSavings: 0,
        downsampleThreshold: 1.0,
      ),
    ),
  ];

  final _files = <PickedDoc>[];
  final _queue = TaskQueue();
  int _presetIndex = 2;
  String? _message;

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onQueueChanged);
  }

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _queue.dispose();
    super.dispose();
  }

  bool get _running => _queue.running;

  void _addFiles(List<PickedDoc> files) {
    setState(() {
      for (final f in files) {
        if (!_files.any((e) => e.name == f.name && e.size == f.size)) {
          _files.add(f);
        }
      }
      _message = null;
    });
  }

  Future<void> _pickFiles() async {
    final files = await pickDocs(extensions: const ['pdf'], multi: true);
    _addFiles(files);
  }

  Future<void> _start() async {
    if (!outputReady) {
      setState(() => _message = '请先选择输出目录');
      return;
    }
    if (_files.isEmpty) return;
    final policy = _presets[_presetIndex].policy;
    _queue.addAll([
      for (final f in _files)
        TaskQueueItem(
          label: f.name,
          sourceSize: f.size,
          task: PdfJobTask(
            () async =>
                PdfCore.instance.compress(await pdfInputOf(f), policy),
          ),
        ),
    ]);
    setState(() {
      _files.clear();
      _message = null;
    });
    await _queue.run();
  }

  /// 已完成条目的总体前后体积；无有效数据时返回 null。
  (int, int)? _summary() {
    var before = 0;
    var after = 0;
    for (final item in _queue.items) {
      if (item.state != TaskState.done || item.outputs.isEmpty) continue;
      final out = item.outputs.first.size;
      if (item.sourceSize == null) continue;
      before += item.sourceSize!;
      after += out;
    }
    return before > 0 ? (before, after) : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PdfDropZone(
      onDocsDropped: _addFiles,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: '1 · 选择 PDF 文件（可多选或直接拖入）',
            trailing: _files.isEmpty
                ? null
                : TextButton(
                    onPressed: () => setState(() => _files.clear()),
                    child: const Text('清空'),
                  ),
            child: Column(
              children: [
                if (_files.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '尚未添加文件',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  )
                else
                  for (var i = 0; i < _files.length; i++)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text(
                        _files[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(sizeLabel(_files[i].size)),
                      trailing: IconButton(
                        onPressed: () => setState(() => _files.removeAt(i)),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: '移除',
                      ),
                    ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.add),
                  label: const Text('添加文件'),
                ),
              ],
            ),
          ),
          SectionCard(
            title: '2 · 压缩档位',
            child: RadioGroup<int>(
              groupValue: _presetIndex,
              onChanged: (v) => setState(() => _presetIndex = v!),
              child: Column(
                children: [
                  for (var i = 0; i < _presets.length; i++)
                    RadioListTile<int>(
                      value: i,
                      title: Text(_presets[i].label),
                      subtitle: Text(_presets[i].description),
                      dense: true,
                    ),
                ],
              ),
            ),
          ),
          const SectionCard(title: '3 · 输出目录', child: OutputDirPicker()),
          SectionCard(
            title: '4 · 任务队列',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: !_running && _files.isNotEmpty
                          ? _start
                          : null,
                      icon: const Icon(Icons.compress),
                      label: Text(
                        _running
                            ? '压缩中…'
                            : '开始压缩（${_files.length} 个文件）',
                      ),
                    ),
                    if (_running)
                      OutlinedButton.icon(
                        onPressed: _queue.cancelAll,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('全部取消'),
                      ),
                    if (!_running && _queue.failedCount > 0)
                      OutlinedButton.icon(
                        onPressed: _queue.retryFailed,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text('重试失败（${_queue.failedCount}）'),
                      ),
                    if (!_running && _queue.hasFinishedWork)
                      TextButton(
                        onPressed: _queue.removeFinished,
                        child: const Text('清除记录'),
                      ),
                  ],
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _message!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                if (_queue.items.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_queue.doneCount} 完成'
                    '${_queue.failedCount > 0 ? ' · ${_queue.failedCount} 失败' : ''}'
                    '${_queue.pendingCount > 0 ? ' · ${_queue.pendingCount} 等待' : ''}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                  const Divider(height: 16),
                  for (final item in _queue.items)
                    _QueueRow(
                      item: item,
                      onCancel: () => _queue.cancelItem(item),
                    ),
                  if (!hasFileSystem && _queue.doneCount > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '点击已完成条目右侧的下载按钮保存到本地',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ],
                if (_summary() case (final before, final after)) ...[
                  const SizedBox(height: 8),
                  _SizeCompare(before: before, after: after),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 队列条目行。
class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.item, required this.onCancel});

  final TaskQueueItem item;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: item.state == TaskState.running
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              switch (item.state) {
                TaskState.pending => Icons.schedule_outlined,
                TaskState.running => Icons.sync,
                TaskState.done => Icons.check_circle,
                TaskState.failed => Icons.error_outline,
                TaskState.cancelled => Icons.cancel_outlined,
              },
              size: 22,
              color: switch (item.state) {
                TaskState.done => Colors.green.shade700,
                TaskState.failed => theme.colorScheme.error,
                TaskState.running => theme.colorScheme.primary,
                _ => theme.hintColor,
              },
            ),
      title: Text(
        item.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _subtitle(theme),
      trailing: item.state == TaskState.pending || item.state == TaskState.running
          ? IconButton(
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
              tooltip: '取消',
            )
          : item.state == TaskState.done &&
                !hasFileSystem &&
                item.outputs.isNotEmpty
          ? IconButton(
              onPressed: () => downloadOutput(item.outputs.first),
              icon: const Icon(Icons.download_outlined, size: 20),
              tooltip: '下载文件',
            )
          : null,
    );
  }

  Widget? _subtitle(ThemeData theme) {
    switch (item.state) {
      case TaskState.pending:
        return const Text('等待中');
      case TaskState.running:
        return const Text('处理中…');
      case TaskState.failed:
        return Text(
          '失败：${item.error}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.colorScheme.error),
        );
      case TaskState.cancelled:
        return const Text('已取消');
      case TaskState.done:
        final out =
            item.outputs.isNotEmpty ? item.outputs.first.size : null;
        if (item.sourceSize == null || out == null) return const Text('完成');
        final saved = item.sourceSize! - out;
        final pct =
            item.sourceSize! > 0 ? (saved * 100 / item.sourceSize!) : 0.0;
        return Text(
          '${formatBytes(item.sourceSize!)} → ${formatBytes(out)}'
          '${saved > 0 ? '（减小 ${pct.toStringAsFixed(1)}%）' : ''}',
        );
    }
  }
}

/// 压缩前后大小对比。
class _SizeCompare extends StatelessWidget {
  const _SizeCompare({required this.before, required this.after});

  final int before;
  final int after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = before - after;
    final percent = before > 0 ? (saved * 100 / before) : 0.0;
    final reduced = saved > 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            reduced ? Icons.trending_down : Icons.trending_flat,
            color: reduced ? Colors.green.shade700 : theme.hintColor,
          ),
          const SizedBox(width: 12),
          Text(
            '${formatBytes(before)} → ${formatBytes(after)}',
            style: theme.textTheme.titleMedium,
          ),
          const Spacer(),
          Text(
            reduced ? '减小 ${percent.toStringAsFixed(1)}%' : '体积未减小',
            style: TextStyle(
              color: reduced ? Colors.green.shade700 : theme.hintColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
