import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../services/preferences_service.dart';
import 'package:provider/provider.dart';
import 'package:charset/charset.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import 'html_viewer_screen.dart';
import 'markdown_viewer_screen.dart';
import '../../services/intent_handler_service.dart';
import '../../services/root_shizuku_service.dart';
import 'internal_file_picker_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class CodeTextEditingController extends TextEditingController {
  String language;
  bool isDark;
  double fontSize;

  // Caching variables for high performance scrolling
  String? _lastParsedText;
  String? _lastParsedLanguage;
  bool? _lastParsedIsDark;
  double? _lastParsedFontSize;
  TextSpan? _lastParsedSpan;

  CodeTextEditingController({
    this.language = 'plain',
    this.isDark = true,
    this.fontSize = 14.0,
    super.text,
  });

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final defaultStyle = style ?? TextStyle(fontFamily: 'monospace', fontSize: fontSize, height: 1.45);
    
    // Bypasses highlighting for large files to guarantee buttery smooth 60fps/120fps scrolling and editing
    final isTooLargeForHighlight = text.length > 50000;
    final effectiveLanguage = isTooLargeForHighlight ? 'plain' : language;

    if (effectiveLanguage == 'plain' || text.isEmpty) {
      return TextSpan(text: text, style: defaultStyle);
    }

    // Cache hit: immediately return cached span during scrolling/selection/caret blink
    if (text == _lastParsedText &&
        effectiveLanguage == _lastParsedLanguage &&
        isDark == _lastParsedIsDark &&
        fontSize == _lastParsedFontSize &&
        _lastParsedSpan != null) {
      return _lastParsedSpan!;
    }

    final commentColor = isDark ? const Color(0xFF7F848E) : const Color(0xFF808080);
    final stringColor = isDark ? const Color(0xFF98C379) : const Color(0xFF008000);
    final keywordColor = isDark ? const Color(0xFFC678DD) : const Color(0xFF0000FF);
    final numberColor = isDark ? const Color(0xFFD19A66) : const Color(0xFFFF8C00);
    final tagColor = isDark ? const Color(0xFF61AFEF) : const Color(0xFF008080);
    final attrColor = isDark ? const Color(0xFFE5C07B) : const Color(0xFFA52A2A);

    RegExp regExp;
    if (effectiveLanguage == 'html' || effectiveLanguage == 'xml') {
      regExp = RegExp(
        r'(?<comment><!--[\s\S]*?-->)|(?<string>"[^"]*"|\x27[^\x27]*\x27)|(?<tag><\/?[\w\-_:]+)|(?<attr>\b[\w\-_:]+)(?=\s*=)',
        multiLine: true,
      );
    } else if (effectiveLanguage == 'json') {
      regExp = RegExp(
        r'(?<string>"[^"]*")|(?<number>\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|(?<keyword>\b(?:true|false|null)\b)',
        multiLine: true,
      );
    } else {
      regExp = RegExp(
        r'(?<comment>\/\*[\s\S]*?\*\/|\/\/.*$|#.*$)|(?<string>"[^"\\]*(?:\\.[^"\\]*)*"|\x27[^\x27\\]*(?:\\.[^\x27\\]*)*\x27)|(?<number>\b\d+(?:\.\d+)?\b)|(?<keyword>\b(?:class|import|package|void|public|private|protected|static|final|const|let|var|function|def|return|if|elif|else|while|for|switch|case|break|continue|true|false|null|new|this|super|extends|implements|async|await|override)\b|\B\.(?:class|super|source|field|method|end method|registers|param|local|line)\b)',
        multiLine: true,
      );
    }

    final matches = regExp.allMatches(text);
    final spans = <TextSpan>[];
    int lastEnd = 0;

    String? getGroup(RegExpMatch m, String name) {
      try {
        if (m.groupNames.contains(name)) {
          return m.namedGroup(name);
        }
      } catch (_) {}
      return null;
    }

    for (final m in matches) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, m.start), style: defaultStyle));
      }

      TextStyle tokenStyle = defaultStyle;
      if (getGroup(m, 'comment') != null) {
        tokenStyle = defaultStyle.copyWith(color: commentColor, fontStyle: FontStyle.italic);
      } else if (getGroup(m, 'string') != null) {
        tokenStyle = defaultStyle.copyWith(color: stringColor);
      } else if (getGroup(m, 'keyword') != null) {
        tokenStyle = defaultStyle.copyWith(color: keywordColor, fontWeight: FontWeight.bold);
      } else if (getGroup(m, 'number') != null) {
        tokenStyle = defaultStyle.copyWith(color: numberColor);
      } else if (getGroup(m, 'tag') != null) {
        tokenStyle = defaultStyle.copyWith(color: tagColor, fontWeight: FontWeight.bold);
      } else if (getGroup(m, 'attr') != null) {
        tokenStyle = defaultStyle.copyWith(color: attrColor);
      }

      spans.add(TextSpan(text: m.group(0), style: tokenStyle));
      lastEnd = m.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: defaultStyle));
    }

    final resultSpan = TextSpan(children: spans);
    
    // Save to cache
    _lastParsedText = text;
    _lastParsedLanguage = effectiveLanguage;
    _lastParsedIsDark = isDark;
    _lastParsedFontSize = fontSize;
    _lastParsedSpan = resultSpan;

    return resultSpan;
  }
}

class TextEditorScreen extends StatefulWidget {
  final String filePath;

  const TextEditorScreen({super.key, required this.filePath});

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  late CodeTextEditingController _controller;
  final ScrollController _textScrollController = ScrollController();
  final ScrollController _lineScrollController = ScrollController();

  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isModified = false;

  bool _showFindReplace = false;
  bool _wordWrap = PreferencesService.getEditorWordWrap();
  bool _readOnly = PreferencesService.getEditorReadOnly();
  bool _showLineNumbers = PreferencesService.getEditorShowLineNumbers();
  String _selectedLanguage = 'auto'; // auto, plain, html, xml, json, dart, java, js, python, cpp, css, smali, markdown
  int _currentLineCount = 1;

  double _fontSize = 14.0;
  double _baseFontSize = 14.0;
  bool _zoomLocked = false;

  final List<String> _history = [];
  final List<String> _redoHistory = [];
  Timer? _debounceTimer;

  final List<String> _quickSymbols = [
    '\t', '{', '}', '[', ']', '(', ')', '<', '>', '/', '\\', '=', '"', '\x27', ':', ';', ',', '.', '+', '-', '*', '&', '|', '!'
  ];

  late final String _initialPath;
  late String _currentFilePath;

  @override
  void initState() {
    super.initState();
    // Normalize path to collapse double slashes
    String norm = widget.filePath.replaceAll(RegExp(r'/+'), '/');
    if (widget.filePath.startsWith('/') && !norm.startsWith('/')) {
      norm = '/$norm';
    }
    _initialPath = norm;
    _currentFilePath = norm;

    _controller = CodeTextEditingController(fontSize: _fontSize);
    _detectLanguage();
    
    _textScrollController.addListener(() {
      if (_lineScrollController.hasClients && _textScrollController.hasClients) {
        final offset = _textScrollController.offset;
        if (_lineScrollController.offset != offset) {
          _lineScrollController.jumpTo(offset);
        }
      }
    });

    _controller.addListener(_onTextChanged);
    _loadFile();
  }

  void _detectLanguage() {
    final ext = p.extension(_currentFilePath).toLowerCase();
    switch (ext) {
      case '.html':
      case '.htm':
        _selectedLanguage = 'html';
        break;
      case '.xml':
        _selectedLanguage = 'xml';
        break;
      case '.json':
        _selectedLanguage = 'json';
        break;
      case '.dart':
        _selectedLanguage = 'dart';
        break;
      case '.java':
        _selectedLanguage = 'java';
        break;
      case '.js':
      case '.ts':
        _selectedLanguage = 'js';
        break;
      case '.py':
        _selectedLanguage = 'python';
        break;
      case '.cpp':
      case '.c':
      case '.h':
        _selectedLanguage = 'cpp';
        break;
      case '.css':
        _selectedLanguage = 'css';
        break;
      case '.smali':
        _selectedLanguage = 'smali';
        break;
      case '.md':
        _selectedLanguage = 'markdown';
        break;
      default:
        _selectedLanguage = 'plain';
        break;
    }
    _controller.language = _selectedLanguage;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.isDark = Theme.of(context).brightness == Brightness.dark;
  }

  void _onTextChanged() {
    if (_isLoading) return;
    final int newLines = _controller.text.split('\n').length;
    if (newLines != _currentLineCount) {
      _currentLineCount = newLines;
      if (mounted) setState(() {});
    }

    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (_history.isEmpty || _history.last != _controller.text) {
        _history.add(_controller.text);
        if (_history.length > 50) _history.removeAt(0); // Max 50 undo steps
        _redoHistory.clear();
      }
      if (!_isModified && mounted) {
        setState(() {
          _isModified = true;
        });
      }
    });
  }

  void _undo() {
    if (_history.length > 1) {
      final current = _history.removeLast();
      _redoHistory.add(current);
      final previous = _history.last;
      
      _controller.removeListener(_onTextChanged);
      _controller.text = previous;
      _currentLineCount = previous.split('\n').length;
      _controller.selection = TextSelection.collapsed(offset: previous.length);
      _controller.addListener(_onTextChanged);
      setState(() {});
    }
  }

  void _redo() {
    if (_redoHistory.isNotEmpty) {
      final next = _redoHistory.removeLast();
      _history.add(next);
      
      _controller.removeListener(_onTextChanged);
      _controller.text = next;
      _currentLineCount = next.split('\n').length;
      _controller.selection = TextSelection.collapsed(offset: next.length);
      _controller.addListener(_onTextChanged);
      setState(() {});
    }
  }

  Future<void> _loadFile() async {
    try {
      final provider = context.read<FileManagerProvider>();
      String content;
      if (provider.isRestrictedPath(_currentFilePath)) {
        final tempDir = Directory('/storage/emulated/0/.nfile_temp');
        if (!tempDir.existsSync()) {
          tempDir.createSync(recursive: true);
        }
        final tempFile = File(p.join(tempDir.path, 'temp_read_${DateTime.now().millisecondsSinceEpoch}.txt'));
        await RootShizukuService.copyItem(_currentFilePath, tempFile.path, useRoot: provider.useRootMode);
        content = _decodeBytesWithFallback(await tempFile.readAsBytes());
        try {
          await tempFile.delete();
        } catch (_) {}
      } else {
        final file = File(_currentFilePath);
        content = _decodeBytesWithFallback(await file.readAsBytes());
      }
      
      _controller.removeListener(_onTextChanged);
      _controller.text = content;
      _currentLineCount = content.split('\n').length;
      _history.add(content);
      _controller.addListener(_onTextChanged);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载文件出错：{e}')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// 尝试多种编码解码字节，优先 UTF-8，回退到 GBK/GB18030，最后 Latin1
  static String _decodeBytesWithFallback(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {}
    try {
      final content = utf8.decode(bytes, allowMalformed: true);
      final replacementCount = '\uFFFD'.allMatches(content).length;
      if (replacementCount <= bytes.length * 0.01) return content;
    } catch (_) {}
    try {
      final decoded = gbk.decode(bytes);
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {}
    return const Latin1Decoder().convert(bytes);
  }

  Future<void> _saveFile() async {
    setState(() => _isSaving = true);
    try {
      final provider = context.read<FileManagerProvider>();
      if (provider.isRestrictedPath(_currentFilePath)) {
        final tempDir = Directory('/storage/emulated/0/.nfile_temp');
        if (!tempDir.existsSync()) {
          tempDir.createSync(recursive: true);
        }
        final tempFile = File(p.join(tempDir.path, 'temp_save_${DateTime.now().millisecondsSinceEpoch}.txt'));
        await tempFile.writeAsString(_controller.text);
        await RootShizukuService.copyItem(tempFile.path, _currentFilePath, useRoot: provider.useRootMode);
        try {
          await tempFile.delete();
        } catch (_) {}
      } else {
        final file = File(_currentFilePath);
        await file.writeAsString(_controller.text);
      }

      try {
        if (mounted) {
          context.read<FileManagerProvider>().updateFileInList(_currentFilePath);
        }
      } catch (_) {}

      if (IntentHandlerService.isIncomingCacheFile(_currentFilePath)) {
        final success = await IntentHandlerService.saveContentUriFile(_currentFilePath, _controller.text);
        if (!success) {
          throw Exception("Failed to save changes back to external storage.");
        }
      }

      if (mounted) {
        setState(() => _isModified = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msg24c6ab0f)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存文件出错：$e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _createNewFile() async {
    final currentDir = p.dirname(_currentFilePath);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final newPath = p.join(currentDir, 'untitled_$timestamp.txt');

    try {
      final file = File(newPath);
      await file.writeAsString('');
      if (mounted) {
        _controller.removeListener(_onTextChanged);
        setState(() {
          _currentFilePath = newPath;
          _controller.text = '';
          _currentLineCount = 1;
          _isModified = false;
          _history.clear();
          _redoHistory.clear();
          _history.add('');
          _readOnly = false;
          _wordWrap = false;
          _showLineNumbers = true;
          _selectedLanguage = 'plain';
          _controller.language = 'plain';
        });
        _controller.addListener(_onTextChanged);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_new_txt)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _saveAsFile() async {
    try {
      // 弹窗让用户选择保存目录
      final selectedDir = await InternalFilePickerScreen.show(
        context,
        rootPath: p.dirname(_currentFilePath),
        pickDirectory: true,
      );
      if (selectedDir == null || selectedDir.isEmpty || !mounted) return;

      final destDir = selectedDir.first;
      final defaultName = p.basenameWithoutExtension(_currentFilePath);

      // 弹窗让用户输入文件名
      final fileNameController = TextEditingController(text: defaultName);
      final fileName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L10n.of(context).ui_save_as),
          content: TextField(
            controller: fileNameController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: L10n.of(context).ui_file_name,
              hintText: defaultName,
              suffixText: '.txt',
            ),
            onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(L10n.of(context).ui_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, fileNameController.text.trim()),
              child: Text(L10n.of(context).ui_confirm),
            ),
          ],
        ),
      );
      fileNameController.dispose();

      if (fileName == null || fileName.isEmpty || !mounted) return;

      var newPath = p.join(destDir, '$fileName.txt');

      // 如果目标文件已存在，自动重命名
      int counter = 1;
      while (File(newPath).existsSync()) {
        newPath = p.join(destDir, '$fileName($counter).txt');
        counter++;
      }

      final provider = context.read<FileManagerProvider>();
      if (provider.isRestrictedPath(newPath)) {
        final tempDir = Directory('/storage/emulated/0/.nfile_temp');
        if (!tempDir.existsSync()) {
          tempDir.createSync(recursive: true);
        }
        final tempFile = File(p.join(tempDir.path, 'temp_saveas_${DateTime.now().millisecondsSinceEpoch}.txt'));
        await tempFile.writeAsString(_controller.text);
        await RootShizukuService.copyItem(tempFile.path, newPath, useRoot: provider.useRootMode);
        try {
          await tempFile.delete();
        } catch (_) {}
      } else {
        final file = File(newPath);
        await file.writeAsString(_controller.text);
      }

      if (mounted) {
        setState(() {
          _currentFilePath = newPath;
          _isModified = false;
        });
        try {
          context.read<FileManagerProvider>().updateFileInList(newPath);
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${L10n.of(context).ui_save_as}: $destDir')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _insertSymbol(String symbol) {
    if (_readOnly) return;
    final text = _controller.text;
    final selection = _controller.selection;
    if (selection.isValid) {
      final newText = text.replaceRange(selection.start, selection.end, symbol);
      final newOffset = selection.start + symbol.length;
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: newOffset);
    } else {
      _controller.text = text + symbol;
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    }
  }

  void _findNext() {
    final query = _findController.text;
    if (query.isEmpty) return;
    final text = _controller.text;
    final start = _controller.selection.end;
    int idx = text.indexOf(query, start);
    if (idx == -1) idx = text.indexOf(query, 0); // Wrap around
    if (idx != -1) {
      _controller.selection = TextSelection(baseOffset: idx, extentOffset: idx + query.length);
    }
  }

  void _replace() {
    if (_readOnly) return;
    final query = _findController.text;
    final replacement = _replaceController.text;
    if (query.isEmpty) return;
    final selection = _controller.selection;
    if (selection.isValid && _controller.text.substring(selection.start, selection.end) == query) {
      final text = _controller.text;
      final newText = text.replaceRange(selection.start, selection.end, replacement);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: selection.start + replacement.length);
      _findNext();
    } else {
      _findNext();
    }
  }

  void _replaceAll() {
    if (_readOnly) return;
    final query = _findController.text;
    final replacement = _replaceController.text;
    if (query.isEmpty) return;
    final text = _controller.text;
    final count = query.allMatches(text).length;
    if (count > 0) {
      _controller.text = text.replaceAll(query, replacement);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已替换 {count} 处')));
    }
  }

  void _showSyntaxPicker() {
    final languages = [
      {'key': 'plain', 'name': L10n.of(context).msgffb01e5b},
      {'key': 'html', 'name': 'HTML'},
      {'key': 'xml', 'name': 'XML'},
      {'key': 'json', 'name': 'JSON'},
      {'key': 'dart', 'name': 'Dart'},
      {'key': 'java', 'name': 'Java'},
      {'key': 'js', 'name': 'JavaScript / TS'},
      {'key': 'python', 'name': 'Python'},
      {'key': 'cpp', 'name': 'C / C++'},
      {'key': 'css', 'name': 'CSS'},
      {'key': 'smali', 'name': 'Smali'},
      {'key': 'markdown', 'name': 'Markdown'},
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(L10n.of(context).msg7902d9c0, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: languages.length,
                itemBuilder: (context, index) {
                  final lang = languages[index];
                  final isSelected = lang['key'] == _selectedLanguage;
                  return ListTile(
                    title: Text(lang['name']!),
                    trailing: isSelected ? Icon(Broken.tick_circle, color: Theme.of(context).colorScheme.primary) : null,
                    onTap: () {
                      setState(() {
                        _selectedLanguage = lang['key']!;
                        _controller.language = lang['key']!;
                      });
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _textScrollController.dispose();
    _lineScrollController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineCount = _currentLineCount;
    final bool isKeyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    final lowerPath = _currentFilePath.toLowerCase();
    final isHtml = lowerPath.endsWith('.html') || lowerPath.endsWith('.htm');
    final isMd = lowerPath.endsWith('.md') || lowerPath.endsWith('.markdown');

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.basename(_currentFilePath),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '$_selectedLanguage • $lineCount ${L10n.of(context).msg_editor_lines}${_isModified ? ' (${L10n.of(context).msg_editor_modified})' : ''}',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Broken.rotate_left),
            tooltip: L10n.of(context).ui_undo,
            onPressed: _history.length > 1 ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Broken.rotate_right_1),
            tooltip: L10n.of(context).ui_redo,
            onPressed: _redoHistory.isNotEmpty ? _redo : null,
          ),
          IconButton(
            icon: const Icon(Broken.add_circle),
            tooltip: L10n.of(context).ui_new_txt,
            onPressed: _createNewFile,
          ),
          IconButton(
            icon: const Icon(Broken.document_copy),
            tooltip: L10n.of(context).ui_save_as,
            onPressed: _saveAsFile,
          ),
          IconButton(
            icon: Icon(_showFindReplace ? Broken.search_zoom_out : Broken.search_normal),
            tooltip: L10n.of(context).msgc856a077,
            onPressed: () => setState(() => _showFindReplace = !_showFindReplace),
          ),
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Broken.save_2),
              tooltip: L10n.of(context).msg7f2c95cd,
              onPressed: _saveFile,
            ),
          PopupMenuButton<String>(
            icon: const Icon(Broken.more),
            tooltip: L10n.of(context).msg3007c452,
            onSelected: (value) async {
              if (value == 'html_preview') {
                if (context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HtmlViewerScreen(
                        filePath: _currentFilePath,
                        initialContent: _controller.text,
                      ),
                    ),
                  );
                }
              } else if (value == 'md_preview') {
                if (context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MarkdownViewerScreen(
                        filePath: _currentFilePath,
                        initialContent: _controller.text,
                      ),
                    ),
                  );
                }
              } else if (value == 'reset_zoom') {
                setState(() {
                  _fontSize = 14.0;
                  _controller.fontSize = 14.0;
                });
              } else if (value == 'lock_zoom') {
                setState(() => _zoomLocked = !_zoomLocked);
              } else if (value == 'word_wrap') {
                setState(() => _wordWrap = !_wordWrap);
                PreferencesService.saveEditorWordWrap(_wordWrap);
              } else if (value == 'read_only') {
                setState(() {
                  _readOnly = !_readOnly;
                  // 阅读模式：开启自动换行、隐藏行号；编辑模式：关闭自动换行、显示行号
                  _wordWrap = _readOnly;
                  _showLineNumbers = !_readOnly;
                });
                PreferencesService.saveEditorReadOnly(_readOnly);
                PreferencesService.saveEditorWordWrap(_wordWrap);
                PreferencesService.saveEditorShowLineNumbers(_showLineNumbers);
              } else if (value == 'toggle_line_numbers') {
                setState(() => _showLineNumbers = !_showLineNumbers);
                PreferencesService.saveEditorShowLineNumbers(_showLineNumbers);
              } else if (value == 'syntax') {
                _showSyntaxPicker();
              }
            },
            itemBuilder: (context) => [
              if (isHtml)
                const PopupMenuItem(
                  value: 'html_preview',
                  child: Row(children: [Icon(Broken.global, size: 18, color: Colors.blueAccent), SizedBox(width: 12), Text('HTML 预览', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent))]),
                ),
              if (isMd)
                PopupMenuItem(
                  value: 'md_preview',
                  child: Row(children: [Icon(Broken.document_text, size: 18, color: Colors.blueAccent), const SizedBox(width: 12), Text(L10n.of(context).markdown, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent))]),
                ),
              PopupMenuItem(
                value: 'reset_zoom',
                child: Row(children: [const Icon(Broken.search_zoom_in_1, size: 18), const SizedBox(width: 12), Text(L10n.of(context).msgDefaultZoom(_fontSize.toInt()))]),
              ),
              PopupMenuItem(
                value: 'lock_zoom',
                child: Row(children: [Icon(_zoomLocked ? Broken.lock_1 : Broken.unlock, size: 18), SizedBox(width: 12), Text(_zoomLocked ? L10n.of(context).msg084e9388 : L10n.of(context).msgLockZoom)]),
              ),
              PopupMenuItem(
                value: 'word_wrap',
                child: Row(children: [Icon(_wordWrap ? Broken.textalign_justifycenter : Broken.textalign_left, size: 18), SizedBox(width: 12), Text(_wordWrap ? L10n.of(context).msgf387265a : L10n.of(context).msg1045ba75)]),
              ),
              PopupMenuItem(
                value: 'read_only',
                child: Row(children: [Icon(_readOnly ? Broken.lock_1 : Broken.edit, size: 18), SizedBox(width: 12), Text(_readOnly ? L10n.of(context).msg96f0ad7d : L10n.of(context).msg349ab61d)]),
              ),
              PopupMenuItem(
                value: 'toggle_line_numbers',
                child: Row(children: [Icon(_showLineNumbers ? Broken.eye_slash : Broken.eye, size: 18), SizedBox(width: 12), Text(_showLineNumbers ? L10n.of(context).msg0cee3cd1 : L10n.of(context).msgc31f9440)]),
              ),
              PopupMenuItem(
                value: 'syntax',
                child: Row(children: [Icon(Broken.code, size: 18), const SizedBox(width: 12), Text(L10n.of(context).selectedlanguage(_selectedLanguage))]),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Find and Replace Toolbar
                if (_showFindReplace)
                  Container(
                    padding: const EdgeInsets.all(8),
                    color: theme.colorScheme.surface,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(Broken.search_normal, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SizedBox(
                                height: 36,
                                child: TextField(
                                  controller: _findController,
                                  decoration: const InputDecoration(
                                    hintText: '查找...',
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                  ),
                                  onSubmitted: (_) => _findNext(),
                                ),
                              ),
                            ),
                            IconButton(icon: const Icon(Broken.arrow_right_3), onPressed: _findNext),
                          ],
                        ),
                        if (!_readOnly) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Broken.edit, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SizedBox(
                                  height: 36,
                                  child: TextField(
                                    controller: _replaceController,
                                    decoration: const InputDecoration(
                                      hintText: '替换为...',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(onPressed: _replace, child: const Text('替换')),
                              const SizedBox(width: 6),
                              ElevatedButton(onPressed: _replaceAll, child: Text(L10n.of(context).msg52709ae1)),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                // Editor and Gutter wrapped in GestureDetector for Pinch-to-Zoom
                Expanded(
                  child: GestureDetector(
                    onScaleStart: (_) {
                      if (_zoomLocked) return;
                      _baseFontSize = _fontSize;
                    },
                    onScaleUpdate: (details) {
                      if (_zoomLocked || details.scale == 1.0) return;
                      final newSize = (_baseFontSize * details.scale).clamp(8.0, 48.0);
                      if ((newSize - _fontSize).abs() > 0.5) {
                        setState(() {
                          _fontSize = newSize;
                          _controller.fontSize = newSize;
                        });
                      }
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line Numbers Gutter
                        if (_showLineNumbers)
                          Container(
                            width: 48,
                            padding: const EdgeInsets.only(top: 12, right: 8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              border: Border(right: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2))),
                            ),
                            child: ListView.builder(
                              controller: _lineScrollController,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: lineCount,
                              itemBuilder: (context, i) => Text(
                                '${i + 1}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: _fontSize,
                                  height: 1.45,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                                ),
                              ),
                            ),
                          ),

                        // Code Editor TextField
                        Expanded(
                          child: _wordWrap
                              ? _buildTextField(theme)
                              : SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  physics: const BouncingScrollPhysics(),
                                  child: SizedBox(
                                    width: MediaQuery.of(context).size.width * 2.5,
                                    child: _buildTextField(theme),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Quick Symbols / Shortcut Bar (MH-TextEditor style)
                if (!_readOnly && isKeyboardVisible)
                  Container(
                    height: 44,
                    color: theme.colorScheme.surface,
                    child: Row(
                      children: [
                        Container(width: 1, height: 24, color: theme.dividerColor.withValues(alpha: 0.2)),
                        Expanded(
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _quickSymbols.length,
                            itemBuilder: (context, index) {
                              final sym = _quickSymbols[index];
                              return InkWell(
                                onTap: () => _insertSymbol(sym),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14),
                                  alignment: Alignment.center,
                                  child: Text(
                                    sym == '\t' ? L10n.of(context).msg4ecba8f6 : sym,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                      fontSize: sym == '\t' ? 12 : 16,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildMenuItem({
    required String label,
    required VoidCallback onPressed,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: _controller,
        scrollController: _textScrollController,
        scrollPhysics: const BouncingScrollPhysics(),
        maxLines: null,
        expands: true,
        readOnly: _readOnly,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: _fontSize,
          height: 1.45,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.only(top: 12, bottom: 48),
        ),
      ),
    );
  }
}
