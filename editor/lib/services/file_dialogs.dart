import 'dart:convert';
import 'dart:io';

/// Windows 原生文件对话框（通过 PowerShell + WinForms 弹出）。
///
/// 不用 file_selector 等插件：Flutter 插件构建需要符号链接（Windows 开发者模式），
/// 普通用户电脑上往往开不了。
class FileDialogs {
  static Future<String> _run(String script) async {
    final full =
        '''[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
'''
        r'''$owner = New-Object System.Windows.Forms.Form -Property @{TopMost = $true; ShowInTaskbar = $false}
'''
        '$script\n';
    // -EncodedCommand 用 UTF-16LE base64，避免中文和引号的转义问题。
    final units = full.codeUnits;
    final bytes = <int>[];
    for (final u in units) {
      bytes
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    final r = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-STA',
        '-NonInteractive',
        '-EncodedCommand',
        base64.encode(bytes),
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return (r.stdout as String).trim();
  }

  static String _q(String s) => "'${s.replaceAll("'", "''")}'";

  /// 选择一张或多张图片；取消时返回空列表。
  static Future<List<String>> pickImages() async {
    final out = await _run(r'''
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = '选择图片'
$d.Filter = '图片|*.png;*.jpg;*.jpeg;*.webp;*.gif|所有文件|*.*'
$d.Multiselect = $true
if ($d.ShowDialog($owner) -eq 'OK') { $d.FileNames | ForEach-Object { Write-Output $_ } }
''');
    return const LineSplitter()
        .convert(out)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// 选择一个或多个 Markdown 文件；取消时返回空列表。
  static Future<List<String>> pickMarkdown() async {
    final out = await _run(r'''
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = '选择 skill 的 .md 文件'
$d.Filter = 'Markdown|*.md;*.markdown|所有文件|*.*'
$d.Multiselect = $true
if ($d.ShowDialog($owner) -eq 'OK') { $d.FileNames | ForEach-Object { Write-Output $_ } }
''');
    return const LineSplitter()
        .convert(out)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// 选择文件夹；取消时返回 null。
  static Future<String?> pickDirectory({
    String? initial,
    String title = '选择工作区文件夹',
  }) async {
    final init = initial != null && Directory(initial).existsSync()
        ? '\$d.SelectedPath = ${_q(initial)}\n'
        : '';
    final out = await _run(
      '\$d = New-Object System.Windows.Forms.FolderBrowserDialog\n'
      '\$d.Description = \${_q(title)}\n'
      '\$d.ShowNewFolderButton = \$true\n'
      '$init'
      'if (\$d.ShowDialog(\$owner) -eq \'OK\') { Write-Output \$d.SelectedPath }',
    );
    return out.isEmpty ? null : out.split('\n').first.trim();
  }
}
