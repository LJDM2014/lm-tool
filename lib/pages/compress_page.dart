import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/app_settings.dart';
import '../services/pdf_service.dart';
import '../widgets/common.dart';

/// 压缩 PDF：四档压缩策略，完成后展示压缩前后大小对比。
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

  File? _file;
  int? _pageCount;
  bool _loadingInfo = false;
  bool _busy = false;
  String? _message;
  int _presetIndex = 2;

  PdfJob<void>? _job;
  File? _result;
  int? _originalSize;
  int? _compressedSize;

  bool get _canStart =>
      !_busy &&
      _file != null &&
      _pageCount != null &&
      AppSettings.outputDir.value != null;

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
      _result = null;
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

  Future<void> _start() async {
    final dirPath = AppSettings.outputDir.value;
    final file = _file;
    if (dirPath == null || file == null) return;
    final policy = _presets[_presetIndex].policy;
    setState(() {
      _busy = true;
      _result = null;
      _message = '正在压缩（${_presets[_presetIndex].label}）…';
      _originalSize = file.lengthSync();
      _compressedSize = null;
    });
    try {
      final job = await PdfService.instance.compress(
        file,
        policy,
        Directory(dirPath),
      );
      setState(() => _job = job);
      await job.done;
      setState(() {
        _result = job.outputs.first;
        _compressedSize = safeFileLength(_result!);
        _message = null;
      });
    } on PdfCancelled {
      _message = '已取消';
    } catch (e) {
      _message = '压缩失败：$e';
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
          title: '4 · 开始压缩',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FilledButton.icon(
                onPressed: _canStart ? _start : null,
                icon: const Icon(Icons.compress),
                label: const Text('压缩'),
              ),
              if (_busy && _message != null) ...[
                const SizedBox(height: 16),
                JobProgressBar(
                  status: _message!,
                  onCancel: () => _job?.cancel(),
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: 16),
                if (_compressedSize != null &&
                    _originalSize != null) ...[
                  _SizeCompare(
                    before: _originalSize!,
                    after: _compressedSize!,
                  ),
                  if (_compressedSize! >= _originalSize!) ...[
                    const SizedBox(height: 8),
                    Text(
                      '提示：该文件以文字/矢量内容为主，或图片本身已经过压缩；'
                      '可尝试切换到"极限压缩"档位。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ],
                const SizedBox(height: 8),
                ResultView(files: [_result!]),
              ],
              if (!_busy && _message != null && _result == null) ...[
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
