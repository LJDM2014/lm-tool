import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/pdf_core.dart';
import '../services/platform_io.dart';
import '../widgets/common.dart';

enum _RangeMode { all, custom }

/// PDF 转图片：把 PDF 逐页渲染导出为 PNG 图片，支持清晰度与页码范围。
class PdfToImagesPage extends StatefulWidget {
  const PdfToImagesPage({super.key});

  @override
  State<PdfToImagesPage> createState() => _PdfToImagesPageState();
}

class _PdfToImagesPageState extends State<PdfToImagesPage> {
  static const _qualities = [
    (label: '标准', description: '最大宽度 1600 px，适合屏幕查看', width: 1600),
    (label: '高清', description: '最大宽度 3000 px，适合投影与缩放', width: 3000),
    (label: '超清', description: '最大宽度 5000 px，适合打印裁切', width: 5000),
  ];

  PickedDoc? _doc;
  PdfInput? _input;
  int? _pageCount;
  bool _loadingInfo = false;

  int _qualityIndex = 0;
  _RangeMode _rangeMode = _RangeMode.all;
  final _rangeCtrl = TextEditingController();

  PdfRenderJob? _job;
  Timer? _poll;
  int _exported = 0;
  List<PdfOutput>? _results;
  String? _message;

  bool get _busy => _job != null;

  bool get _canStart =>
      !_busy &&
      _input != null &&
      _pageCount != null &&
      outputReady &&
      (_rangeMode == _RangeMode.all ||
          parsePageRanges(_rangeCtrl.text, _pageCount!) != null);

  Future<void> _pickFile() async {
    final docs = await pickDocs(
      extensions: const ['pdf'],
    );
    if (docs.isEmpty) return;
    await _useDoc(docs.first);
  }

  Future<void> _useDoc(PickedDoc doc) async {
    setState(() {
      _doc = doc;
      _input = null;
      _pageCount = null;
      _loadingInfo = true;
      _results = null;
      _message = null;
    });
    try {
      final input = await pdfInputOf(doc);
      final count = await PdfCore.instance.pageCount(input);
      if (mounted) {
        setState(() {
          _input = input;
          _pageCount = count;
          _loadingInfo = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingInfo = false;
          _message = '无法读取该文件：$e';
        });
      }
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _busy) setState(() => _exported = _job!.exportedCount);
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _start() async {
    final input = _input;
    if (input == null) return;
    final pages = _rangeMode == _RangeMode.custom
        ? parsePageRanges(_rangeCtrl.text, _pageCount!)
        : null;
    setState(() {
      _results = null;
      _exported = 0;
      _message = '正在导出页面…';
    });
    try {
      final job = await PdfCore.instance.pdfToImages(
        input,
        maxWidth: _qualities[_qualityIndex].width,
        pages: pages,
      );
      setState(() => _job = job);
      _startPolling();
      final outputs = await job.done;
      await saveOutputs(outputs);
      if (mounted) {
        setState(() {
          _results = outputs;
          _message = null;
        });
      }
    } on PdfCancelled {
      if (mounted) setState(() => _message = '已取消');
    } catch (e) {
      if (mounted) setState(() => _message = '导出失败：$e');
    } finally {
      _stopPolling();
      if (mounted) setState(() => _job = null);
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _rangeCtrl.dispose();
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
                      '尚未选择文件',
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
                      _loadingInfo
                          ? '读取中…'
                          : _pageCount == null
                              ? '页数未知'
                              : '共 $_pageCount 页 · ${sizeLabel(_doc!.size)}',
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
          SectionCard(
            title: '2 · 清晰度',
            child: RadioGroup<int>(
              groupValue: _qualityIndex,
              onChanged: (v) => setState(() => _qualityIndex = v!),
              child: Column(
                children: [
                  for (var i = 0; i < _qualities.length; i++)
                    RadioListTile<int>(
                      value: i,
                      title: Text(_qualities[i].label),
                      subtitle: Text(_qualities[i].description),
                      dense: true,
                    ),
                ],
              ),
            ),
          ),
          SectionCard(
            title: '3 · 页码范围',
            child: Column(
              children: [
                RadioGroup<_RangeMode>(
                  groupValue: _rangeMode,
                  onChanged: (v) => setState(() => _rangeMode = v!),
                  child: Column(
                    children: [
                      RadioListTile<_RangeMode>(
                        value: _RangeMode.all,
                        title: const Text('全部页'),
                        dense: true,
                      ),
                      RadioListTile<_RangeMode>(
                        value: _RangeMode.custom,
                        title: const Text('指定页'),
                        dense: true,
                      ),
                    ],
                  ),
                ),
                if (_rangeMode == _RangeMode.custom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _rangeCtrl,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        hintText: '如 1-3,5（兼容中文逗号）',
                        errorText: (_pageCount != null &&
                                _rangeCtrl.text.isNotEmpty &&
                                parsePageRanges(
                                      _rangeCtrl.text,
                                      _pageCount!,
                                    ) ==
                                    null)
                            ? '页码格式无效或超出范围'
                            : null,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
              ],
            ),
          ),
          const SectionCard(title: '4 · 输出目录', child: OutputDirPicker()),
          SectionCard(
            title: '5 · 开始',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _canStart ? _start : null,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(_busy ? '导出中…' : '开始导出 PNG'),
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
                    status: _pageCount == null || _exported == 0
                        ? '正在导出页面…'
                        : '已导出 $_exported / $_pageCount 页…',
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
