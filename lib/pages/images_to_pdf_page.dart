import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/pdf_core.dart';
import '../services/platform_io.dart';
import '../widgets/common.dart';

/// 图片转 PDF：多选/拖入 JPG/PNG 图片，按顺序每张一页合成 PDF。
class ImagesToPdfPage extends StatefulWidget {
  const ImagesToPdfPage({super.key});

  @override
  State<ImagesToPdfPage> createState() => _ImagesToPdfPageState();
}

class _ImagesToPdfPageState extends State<ImagesToPdfPage> {
  static const _extensions = ['jpg', 'jpeg', 'png'];

  final _images = <PickedDoc>[];
  PdfJob<void>? _job;
  List<PdfOutput>? _results;
  String? _message;

  bool get _busy => _job != null;

  void _addFiles(List<PickedDoc> files) {
    setState(() {
      for (final f in files) {
        if (!_images.any((e) => e.name == f.name && e.size == f.size)) {
          _images.add(f);
        }
      }
      _message = null;
    });
  }

  Future<void> _pickImages() async {
    final files = await pickDocs(extensions: _extensions, multi: true);
    _addFiles(files);
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _images.length) return;
    setState(() {
      final f = _images.removeAt(index);
      _images.insert(target, f);
      _results = null;
    });
  }

  Future<void> _start() async {
    if (!outputReady) {
      setState(() => _message = '请先选择输出目录');
      return;
    }
    if (_images.isEmpty) return;
    setState(() {
      _results = null;
      _message = '正在合成 PDF…';
    });
    try {
      final job = await PdfCore.instance.imagesToPdf(
        [for (final f in _images) await pdfInputOf(f)],
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
      if (mounted) setState(() => _message = '转换失败：$e');
    } finally {
      if (mounted) setState(() => _job = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PdfDropZone(
      extensions: _extensions,
      onDocsDropped: _busy ? (_) {} : _addFiles,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: '1 · 选择图片（可多选或直接拖入，JPG / PNG）',
            trailing: _images.isEmpty
                ? null
                : TextButton(
                    onPressed: _busy ? null : () => setState(() {
                          _images.clear();
                          _results = null;
                        }),
                    child: const Text('清空'),
                  ),
            child: Column(
              children: [
                if (_images.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '尚未添加图片',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  )
                else
                  for (var i = 0; i < _images.length; i++)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.image_outlined),
                      title: Text(
                        _images[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(sizeLabel(_images[i].size)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed:
                                _busy || i == 0 ? null : () => _move(i, -1),
                            icon: const Icon(Icons.arrow_upward, size: 18),
                            tooltip: '上移',
                          ),
                          IconButton(
                            onPressed: _busy || i == _images.length - 1
                                ? null
                                : () => _move(i, 1),
                            icon: const Icon(Icons.arrow_downward, size: 18),
                            tooltip: '下移',
                          ),
                          IconButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _images.removeAt(i)),
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: '移除',
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _pickImages,
                  icon: const Icon(Icons.add),
                  label: const Text('添加图片'),
                ),
              ],
            ),
          ),
          const SectionCard(title: '2 · 输出目录', child: OutputDirPicker()),
          SectionCard(
            title: '3 · 开始',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: !_busy && _images.isNotEmpty ? _start : null,
                      icon: const Icon(Icons.auto_awesome_motion_outlined),
                      label: Text(
                        _busy ? '合成中…' : '开始合成（${_images.length} 张图片）',
                      ),
                    ),
                    if (_busy)
                      OutlinedButton.icon(
                        onPressed: () => _job?.cancel(),
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('取消'),
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
