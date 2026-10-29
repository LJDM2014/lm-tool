import 'package:flutter/material.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../services/pdf_core.dart';
import '../services/platform_io.dart';
import '../widgets/common.dart';

/// 加密保护：为 PDF 设置打开/权限密码，或移除已有加密。
class ProtectPage extends StatefulWidget {
  const ProtectPage({super.key});

  @override
  State<ProtectPage> createState() => _ProtectPageState();
}

class _ProtectPageState extends State<ProtectPage> {
  PickedDoc? _doc;
  PdfInput? _input;
  PdfDocInfo? _info;
  bool _loadingInfo = false;
  String? _password; // 解锁已加密文件时缓存的密码

  final _ownerCtrl = TextEditingController();
  final _ownerConfirmCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  bool _allowPrint = true;
  bool _allowCopy = true;
  bool _allowModify = false;
  bool _useAes128 = false;

  PdfJob<void>? _job;
  List<PdfOutput>? _results;
  String? _message;

  bool get _busy => _job != null;

  bool get _isEncrypted => _info?.isEncrypted ?? false;

  bool get _canEncrypt =>
      !_busy &&
      _input != null &&
      !_isEncrypted &&
      _ownerCtrl.text.isNotEmpty &&
      _ownerCtrl.text == _ownerConfirmCtrl.text;

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
      _info = null;
      _password = null;
      _loadingInfo = true;
      _results = null;
      _message = null;
    });
    try {
      final input = await pdfInputOf(doc);
      final info = await PdfCore.instance.pdfInfo(input);
      if (mounted) {
        setState(() { _input = input; _info = info; _loadingInfo = false; });
      }
    } catch (_) {
      // 无密码打不开（或文件损坏）：需要密码解锁。
      final pwd = await _promptPassword();
      if (pwd == null) {
        if (mounted) {
          setState(() { _loadingInfo = false; _message = '已取消'; });
        }
        return;
      }
      try {
        final input = await pdfInputOf(doc);
        final info = await PdfCore.instance.pdfInfo(input, password: pwd);
        if (mounted) {
          setState(() {
            _input = input;
            _info = info;
            _password = pwd;
            _loadingInfo = false;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() { _loadingInfo = false; _message = '无法读取该文件：$e'; });
        }
      }
    }
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

  PdfPermissions _permissions() => PdfPermissions(
        print: _allowPrint,
        printHq: _allowPrint,
        copy: _allowCopy,
        modify: _allowModify,
        annotate: _allowModify,
        fillForms: true,
        accessibility: true,
        assemble: _allowModify,
      );

  Future<void> _encrypt() async {
    final input = _input;
    if (input == null || !_canEncrypt) return;
    setState(() { _results = null; _message = '正在加密…'; });
    try {
      final job = await PdfCore.instance.encrypt(
        input,
        ownerPassword: _ownerCtrl.text,
        userPassword: _userCtrl.text.isEmpty ? null : _userCtrl.text,
        algorithm: _useAes128
            ? PdfEncryptionAlgorithm.aes128
            : PdfEncryptionAlgorithm.aes256,
        permissions: _permissions(),
      );
      setState(() => _job = job);
      await job.done;
      await saveOutputs(job.outputs);
      if (mounted) setState(() { _results = job.outputs; _message = null; });
    } on PdfCancelled {
      if (mounted) setState(() => _message = '已取消');
    } catch (e) {
      if (mounted) setState(() => _message = '加密失败：$e');
    } finally {
      if (mounted) setState(() => _job = null);
    }
  }

  Future<void> _decrypt() async {
    final input = _input;
    if (input == null || _password == null) return;
    setState(() { _results = null; _message = '正在解密…'; });
    try {
      final job = await PdfCore.instance.decrypt(input, _password!);
      setState(() => _job = job);
      await job.done;
      await saveOutputs(job.outputs);
      if (mounted) setState(() { _results = job.outputs; _message = null; });
    } on PdfCancelled {
      if (mounted) setState(() => _message = '已取消');
    } catch (e) {
      if (mounted) setState(() => _message = '解密失败：$e');
    } finally {
      if (mounted) setState(() => _job = null);
    }
  }

  @override
  void dispose() {
    _ownerCtrl.dispose();
    _ownerConfirmCtrl.dispose();
    _userCtrl.dispose();
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
                    child: Text('尚未选择文件', style: TextStyle(color: theme.hintColor)),
                  )
                else
                  ListTile(
                    dense: true,
                    leading: Icon(
                      _isEncrypted ? Icons.lock : Icons.lock_open,
                      color: _isEncrypted ? theme.colorScheme.primary : null,
                    ),
                    title: Text(
                      _doc!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _loadingInfo
                          ? '读取中…'
                          : _info == null
                              ? '信息未知'
                              : '共 ${_info!.pageCount} 页 · '
                                  '${_isEncrypted ? '已加密（${_info!.algorithm?.name ?? '未知算法'}）' : '未加密'}'
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
          if (!_loadingInfo && _info != null && !_isEncrypted)
            SectionCard(
              title: '3 · 设置加密',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _ownerCtrl,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '权限密码（必填，拥有全部权限）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ownerConfirmCtrl,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '确认权限密码',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: _ownerConfirmCtrl.text.isNotEmpty &&
                              _ownerCtrl.text != _ownerConfirmCtrl.text
                          ? '两次输入不一致'
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _userCtrl,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '打开密码（可选，留空则无需密码即可打开）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  CheckboxListTile(
                    dense: true,
                    value: _allowPrint,
                    onChanged: _busy ? null : (v) => setState(() => _allowPrint = v!),
                    title: const Text('允许打印'),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: _allowCopy,
                    onChanged: _busy ? null : (v) => setState(() => _allowCopy = v!),
                    title: const Text('允许复制文字'),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: _allowModify,
                    onChanged: _busy ? null : (v) => setState(() => _allowModify = v!),
                    title: const Text('允许修改内容'),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: _useAes128,
                    onChanged: _busy ? null : (v) => setState(() => _useAes128 = v!),
                    title: const Text('使用 AES-128（默认 AES-256，兼容旧阅读器时勾选）'),
                  ),
                ],
              ),
            ),
          SectionCard(
            title: '4 · 开始',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!_isEncrypted)
                      FilledButton.icon(
                        onPressed: _canEncrypt ? _encrypt : null,
                        icon: const Icon(Icons.lock),
                        label: const Text('加密并保存'),
                      )
                    else
                      FilledButton.icon(
                        onPressed:
                            !_busy && _input != null && _password != null
                                ? _decrypt
                                : null,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('解密并保存副本'),
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
                  Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
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
