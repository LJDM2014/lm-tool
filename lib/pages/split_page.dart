import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/app_settings.dart';
import '../services/pdf_service.dart';
import '../widgets/common.dart';

/// 拆分 PDF：按每 N 页一份，或提取指定页码范围。
class SplitPage extends StatefulWidget {
  const SplitPage({super.key});

  @override
  State<SplitPage> createState() => _SplitPageState();
}

enum _SplitMode { every, extract }

class _SplitPageState extends State<SplitPage> {
  File? _file;
  int? _pageCount;
  bool _loadingInfo = false;
  bool _busy = false;
  String? _message;

  _SplitMode _mode = _SplitMode.every;
  int _every = 1;
  final _rangeCtrl = TextEditingController();

  PdfJob<void>? _job;
  List<File>? _results;

  bool get _canStart =>
      !_busy &&
      _file != null &&
      _pageCount != null &&
      AppSettings.outputDir.value != null &&
      (_mode == _SplitMode.every ||
          _parseRanges(_rangeCtrl.text) != null);

  Future<void> _pickFile() async {
    final pf = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (pf == null) return;
    final file = File(pf.path!);
    setState(() {
      _file = file;
      _pageCount = null;
      _loadingInfo = true;
      _results = null;
      _message = null;
    });
    try {
      final count = await PdfService.instance.pageCount(file);
      if (mounted) {
        setState(() {
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

  /// 解析 "1-3,5" 形式的页码范围，返回 0 起始页码列表；非法输入返回 null。
  List<int>? _parseRanges(String input) {
    final max = _pageCount;
    if (max == null) return null;
    final pages = <int>{};
    for (final part in input.split(RegExp('[,，]'))) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final m = RegExp(r'^(\d+)(?:\s*-\s*(\d+))?$').firstMatch(p);
      if (m == null) return null;
      final a = int.parse(m.group(1)!);
      final b = m.group(2) == null ? a : int.parse(m.group(2)!);
      if (a < 1 || b < a || b > max) return null;
      for (var i = a; i <= b; i++) {
        pages.add(i - 1);
      }
    }
    if (pages.isEmpty) return null;
    return pages.toList()..sort();
  }

  Future<void> _start() async {
    final dirPath = AppSettings.outputDir.value;
    if (dirPath == null || _file == null) return;
    final file = _file!;
    setState(() {
      _busy = true;
      _results = null;
      _message = _mode == _SplitMode.every
          ? '正在按每 $_every 页拆分…'
          : '正在提取指定页面…';
    });
    try {
      final PdfJob<void> job;
      if (_mode == _SplitMode.every) {
        job = await PdfService.instance.splitEvery(
          file,
          _every,
          Directory(dirPath),
        );
      } else {
        final pages = _parseRanges(_rangeCtrl.text)!;
        job = await PdfService.instance.extractPages(
          file,
          pages,
          Directory(dirPath),
          nameSuffix: 'pages-${_rangeCtrl.text.trim().replaceAll(' ', '')}',
        );
      }
      setState(() => _job = job);
      await job.done;
      setState(() {
        _results = job.outputs;
        _message = null;
      });
    } on PdfCancelled {
      _message = '已取消';
    } catch (e) {
      _message = '操作失败：$e';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _job = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _rangeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: '1 · 选择 PDF 文件',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _file == null
                          ? '尚未选择文件'
                          : '${_file!.uri.pathSegments.last}'
                              '${fileSizePart(_file!)}'
                              '${_pageCount != null ? ' · $_pageCount 页' : ''}）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _file == null ? theme.hintColor : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFile,
                    icon: const Icon(Icons.add),
                    label: Text(_file == null ? '选择文件' : '重新选择'),
                  ),
                ],
              ),
              if (_loadingInfo)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
        SectionCard(
          title: '2 · 拆分方式',
          child: RadioGroup<_SplitMode>(
            groupValue: _mode,
            onChanged: (v) => setState(() => _mode = v!),
            child: Column(
              children: [
                RadioListTile<_SplitMode>(
                  value: _SplitMode.every,
                  title: const Text('按页数拆分'),
                  subtitle: const Text('每 N 页生成一个新文件'),
                  dense: true,
                ),
                if (_mode == _SplitMode.every)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, right: 16),
                    child: Row(
                      children: [
                        const Text('每'),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 120,
                          child: DropdownButtonFormField<int>(
                            initialValue: _every,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: [
                              for (final n in [1, 2, 3, 5, 10, 20, 50])
                                DropdownMenuItem(value: n, child: Text('$n 页')),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _every = v ?? 1),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text('生成一份'),
                      ],
                    ),
                  ),
                RadioListTile<_SplitMode>(
                  value: _SplitMode.extract,
                  title: const Text('提取指定页面'),
                  subtitle: const Text('把选中的页保存为一个新的 PDF'),
                  dense: true,
                ),
                if (_mode == _SplitMode.extract)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, right: 16),
                    child: TextField(
                      controller: _rangeCtrl,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        hintText: '例如：1-3,5',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        errorText: _parseRanges(_rangeCtrl.text) == null &&
                                _rangeCtrl.text.isNotEmpty
                            ? '页码格式无效或超出范围'
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SectionCard(title: '3 · 输出目录', child: OutputDirPicker()),
        SectionCard(
          title: '4 · 开始拆分',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FilledButton.icon(
                onPressed: _canStart ? _start : null,
                icon: const Icon(Icons.call_split),
                label: const Text('拆分'),
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
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
