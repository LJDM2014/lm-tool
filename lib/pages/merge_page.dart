import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/app_settings.dart';
import '../services/pdf_service.dart';
import '../widgets/common.dart';

/// 合并 PDF：多选文件（可排序），合并为单个文件。
class MergePage extends StatefulWidget {
  const MergePage({super.key});

  @override
  State<MergePage> createState() => _MergePageState();
}

class _MergePageState extends State<MergePage> {
  final _files = <File>[];
  bool _busy = false;
  String? _message;
  PdfJob<void>? _job;
  List<File>? _results;

  bool get _canStart => !_busy && _files.length >= 2;

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (files.isEmpty) return;
    setState(() {
      _files.addAll([for (final f in files) File(f.path!)]);
      _results = null;
      _message = null;
    });
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _files.length) return;
    setState(() {
      final f = _files.removeAt(index);
      _files.insert(target, f);
    });
  }

  Future<void> _start() async {
    final dirPath = _requireOutputDir();
    if (dirPath == null) return;
    setState(() {
      _busy = true;
      _message = '正在合并 ${_files.length} 个文件…';
      _results = null;
    });
    try {
      final job = await PdfService.instance.merge(_files, Directory(dirPath));
      setState(() => _job = job);
      await job.done;
      setState(() {
        _results = job.outputs;
        _message = null;
      });
    } on PdfCancelled {
      _message = '已取消';
    } catch (e) {
      _message = '合并失败：$e';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _job = null;
        });
      }
    }
  }

  String? _requireOutputDir() {
    final dir = AppSettings.outputDir.value;
    if (dir != null) return dir;
    setState(() => _message = '请先选择输出目录');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: '1 · 选择 PDF 文件（至少 2 个）',
          trailing: _files.isEmpty
              ? null
              : TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _files.clear();
                          _results = null;
                        }),
                  child: const Text('清空'),
                ),
          child: Column(
            children: [
              if (_files.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    '尚未添加文件',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                )
              else
                for (var i = 0; i < _files.length; i++)
                  _FileRow(
                    file: _files[i],
                    index: i,
                    count: _files.length,
                    enabled: !_busy,
                    onMove: (d) => _move(i, d),
                    onRemove: () => setState(() {
                      _files.removeAt(i);
                      _results = null;
                    }),
                  ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFiles,
                icon: const Icon(Icons.add),
                label: const Text('添加文件'),
              ),
            ],
          ),
        ),
        const SectionCard(title: '2 · 输出目录', child: OutputDirPicker()),
        SectionCard(
          title: '3 · 开始合并',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FilledButton.icon(
                onPressed: _canStart ? _start : null,
                icon: const Icon(Icons.merge_type),
                label: const Text('合并'),
              ),
              if (_busy && _message != null) ...[
                const SizedBox(height: 16),
                JobProgressBar(
                  status: _message!,
                  onCancel: () => _job?.cancel(),
                ),
              ],
              if (_results != null) ...[
                const SizedBox(height: 16),
                ResultView(files: _results!),
              ],
              if (!_busy && _message != null && _results == null) ...[
                const SizedBox(height: 16),
                Text(
                  _message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onMove,
    required this.onRemove,
  });

  final File file;
  final int index;
  final int count;
  final bool enabled;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = file.uri.pathSegments.last;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.picture_as_pdf_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(fileSizeLabel(file)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: enabled && index > 0 ? () => onMove(-1) : null,
            icon: const Icon(Icons.arrow_upward, size: 20),
            tooltip: '上移',
          ),
          IconButton(
            onPressed: enabled && index < count - 1 ? () => onMove(1) : null,
            icon: const Icon(Icons.arrow_downward, size: 20),
            tooltip: '下移',
          ),
          IconButton(
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: '移除',
          ),
        ],
      ),
    );
  }
}


