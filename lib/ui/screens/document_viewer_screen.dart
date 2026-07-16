import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:excel/excel.dart' as excel_pkg;
import 'package:excel2003/excel2003.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:xml/xml.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class DocumentViewerScreen extends StatefulWidget {
  final String filePath;

  const DocumentViewerScreen({super.key, required this.filePath});

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  String get _fileName => widget.filePath.split('/').last;
  String get _ext =>
      _fileName.contains('.')
          ? _fileName.substring(_fileName.lastIndexOf('.')).toLowerCase()
          : '';

  bool get _isPdf => _ext == '.pdf';
  bool get _isWord => _ext == '.doc' || _ext == '.docx';
  bool get _isExcel => _ext == '.xls' || _ext == '.xlsx';
  bool get _isPpt => _ext == '.ppt' || _ext == '.pptx';

  bool get _isText =>
      _ext == '.txt' ||
      _ext == '.csv' ||
      _ext == '.rtf' ||
      _ext == '.log' ||
      _ext == '.md';

  String _textContent = '';
  final Map<String, List<List<dynamic>>> _excelSheets = {};
  String _selectedSheet = '';
  List<String> _pptSlides = [];

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEditing = false;
  bool _wordWrap = true;
  bool _showLineNumbers = false;
  late TextEditingController _textController;
  final FocusNode _textFieldFocusNode = FocusNode();
  final List<String> _undoStack = [];

  PdfPageLayoutMode _pdfLayoutMode = PdfPageLayoutMode.continuous;
  PdfScrollDirection _pdfScrollDirection = PdfScrollDirection.vertical;
  bool _pdfEnableTextSelection = true;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    if (_isText) {
      _loadTextFile();
    } else if (_isWord) {
      _loadWordFile();
    } else if (_isExcel) {
      _loadExcelFile();
    } else if (_isPpt) {
      _loadPptFile();
    } else {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFieldFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadTextFile() async {
    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        String content = _decodeBytesWithFallback(bytes);
        _textController.text = content;
        _textContent = content;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载出错：{e}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 尝试多种编码解码字节，优先 UTF-8，回退到 GBK，最后 Latin1
  static String _decodeBytesWithFallback(List<int> bytes) {
    // 1. 尝试 UTF-8 严格解码
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {}

    // 2. 尝试带容错的 UTF-8，检查替换字符比例
    try {
      final content = utf8.decode(bytes, allowMalformed: true);
      final replacementCount = '\uFFFD'.allMatches(content).length;
      if (replacementCount <= bytes.length * 0.01) {
        return content;
      }
    } catch (_) {}

    // 3. 尝试 GBK 解码（覆盖 GB2312/GBK 中文编码）
    try {
      final decoded = gbk.decode(bytes);
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {}

    // 4. 最终回退：Latin1（每个字节映射到一个字符，不会失败）
    return const Latin1Decoder().convert(bytes);
  }

  Future<void> _loadWordFile() async {
    try {
      final file = File(widget.filePath);
      final bytes = await file.readAsBytes();
      final text = docxToText(bytes);
      _textContent = text;
      _textController.text = text;
    } catch (e) {
      debugPrint('Error reading Word: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadExcelFile() async {
    try {
      final file = File(widget.filePath);
      final bytes = await file.readAsBytes();

      _excelSheets.clear();

      if (_ext == '.xls') {
        final xls = XlsReader.fromBytes(bytes);
        for (final sheetName in xls.sheetNames) {
          final sheet = xls.sheetByName(sheetName);
          if (sheet != null) {
            final List<List<dynamic>> rowsStr = [];
            for (final r in sheet.rows) {
              rowsStr.add(r.map((c) => c?.toString() ?? '').toList());
            }
            _excelSheets[sheetName] = rowsStr;
          }
        }
      } else {
        final excel = excel_pkg.Excel.decodeBytes(bytes);
        for (final table in excel.tables.keys) {
          final sheet = excel.tables[table]!;
          final List<List<dynamic>> rows = [];
          for (final row in sheet.rows) {
            final List<dynamic> rowData = [];
            for (final cell in row) {
              rowData.add(cell?.value?.toString() ?? '');
            }
            rows.add(rowData);
          }
          _excelSheets[table] = rows;
        }
      }

      if (_excelSheets.isNotEmpty) {
        _selectedSheet = _excelSheets.keys.first;
      }
    } catch (e) {
      debugPrint('Error reading Excel: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPptFile() async {
    try {
      final file = File(widget.filePath);
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final slideMap = <int, String>{};

      for (final file in archive.files) {
        if (file.name.startsWith('ppt/slides/slide') && file.name.endsWith('.xml')) {
          final match = RegExp(r'slide(\d+)\.xml').firstMatch(file.name);
          if (match != null) {
            final slideNum = int.parse(match.group(1)!);
            final contentStr = utf8.decode(file.content as List<int>);
            final doc = XmlDocument.parse(contentStr);
            final textNodes = doc.findAllElements('a:t');
            final slideText = textNodes.map((node) => node.innerText).where((t) => t.trim().isNotEmpty).join('\n');
            slideMap[slideNum] = slideText.isEmpty ? L10n.of(context).msg5937f822 : slideText;
          }
        }
      }

      final sortedKeys = slideMap.keys.toList()..sort();
      _pptSlides = sortedKeys.map((k) => slideMap[k]!).toList();
    } catch (e) {
      debugPrint('Error reading PPTX: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveFile() async {
    setState(() => _isSaving = true);
    try {
      final file = File(widget.filePath);
      await file.writeAsString(_textController.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存成功 ✓'),
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isEditing = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存出错：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _openExternal() async {
    await OpenFilex.open(widget.filePath);
  }

  Future<void> _createNewFile() async {
    final directory = File(widget.filePath).parent;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final newPath = '${directory.path}/untitled_$timestamp.txt';
    final file = File(newPath);
    await file.writeAsString('');
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(
        builder: (_) => DocumentViewerScreen(filePath: newPath),
      ));
    }
  }

  void _enterEditMode() {
    _undoStack.add(_textController.text);
    setState(() => _isEditing = true);
  }

  void _showPdfSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final theme = Theme.of(context);
            final isDark = theme.brightness == Brightness.dark;
            return Container(
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.4 : 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              padding: EdgeInsets.only(
                top: 16,
                left: 24,
                right: 24,
                bottom: MediaQuery.of(context).padding.bottom + 24,
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Handle
                      Center(
                        child: Container(
                          width: 48,
                          height: 5,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurface.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.speed_rounded,
                                color: theme.colorScheme.primary,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                L10n.of(context).pdf,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: Icon(Icons.close_rounded, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L10n.of(context).msg09c933bf,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Quick Tuning Presets
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.primary.withOpacity(0.2),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '快速性能预设',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Preset Buttons
                            Row(
                              children: [
                                Expanded(
                                  child: _buildPresetButton(
                                    context: context,
                                    label: L10n.of(context).msg701a85d4,
                                    subtitle: L10n.of(context).msg2722d1a7,
                                    isActive: _pdfLayoutMode == PdfPageLayoutMode.continuous && _pdfEnableTextSelection,
                                    onTap: () {
                                      setModalState(() {
                                        _pdfLayoutMode = PdfPageLayoutMode.continuous;
                                        _pdfScrollDirection = PdfScrollDirection.vertical;
                                        _pdfEnableTextSelection = true;
                                      });
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _buildPresetButton(
                                    context: context,
                                    label: '流畅模式',
                                    subtitle: L10n.of(context).msgb2b08d54,
                                    isActive: _pdfLayoutMode == PdfPageLayoutMode.single && !_pdfEnableTextSelection,
                                    onTap: () {
                                      setModalState(() {
                                        _pdfLayoutMode = PdfPageLayoutMode.single;
                                        _pdfScrollDirection = PdfScrollDirection.horizontal;
                                        _pdfEnableTextSelection = false;
                                      });
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Detail Tuning header
                      Text(
                        '详细调节选项',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),

                      // Page Layout Option
                      _buildTuningOption(
                        context: context,
                        title: L10n.of(context).msg8b519c02,
                        subtitle: _pdfLayoutMode == PdfPageLayoutMode.continuous
                            ? L10n.of(context).msg7f2cd152
                            : '单页（逐页滑动）',
                        child: SegmentedButton<PdfPageLayoutMode>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            selectedBackgroundColor: theme.colorScheme.primary.withOpacity(0.12),
                            selectedForegroundColor: theme.colorScheme.primary,
                          ),
                          segments: const [
                            ButtonSegment<PdfPageLayoutMode>(
                              value: PdfPageLayoutMode.continuous,
                              icon: Icon(Icons.view_day_outlined, size: 18),
                              label: Text('连续'),
                            ),
                            ButtonSegment<PdfPageLayoutMode>(
                              value: PdfPageLayoutMode.single,
                              icon: Icon(Icons.auto_stories_outlined, size: 18),
                              label: Text('单页'),
                            ),
                          ],
                          selected: {_pdfLayoutMode},
                          onSelectionChanged: (newSelection) {
                            setModalState(() {
                              _pdfLayoutMode = newSelection.first;
                              if (_pdfLayoutMode == PdfPageLayoutMode.single) {
                                _pdfScrollDirection = PdfScrollDirection.horizontal;
                              } else {
                                _pdfScrollDirection = PdfScrollDirection.vertical;
                              }
                            });
                            setState(() {});
                          },
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Scroll Direction Option
                      _buildTuningOption(
                        context: context,
                        title: L10n.of(context).msg151ea324,
                        subtitle: _pdfScrollDirection == PdfScrollDirection.vertical
                            ? L10n.of(context).msg7d45ded6
                            : '水平（从左到右滑动）',
                        child: SegmentedButton<PdfScrollDirection>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            selectedBackgroundColor: theme.colorScheme.primary.withOpacity(0.12),
                            selectedForegroundColor: theme.colorScheme.primary,
                          ),
                          segments: const [
                            ButtonSegment<PdfScrollDirection>(
                              value: PdfScrollDirection.vertical,
                              icon: Icon(Icons.swap_vert_rounded, size: 18),
                              label: Text('垂直'),
                            ),
                            ButtonSegment<PdfScrollDirection>(
                              value: PdfScrollDirection.horizontal,
                              icon: Icon(Icons.swap_horiz_rounded, size: 18),
                              label: Text('水平'),
                            ),
                          ],
                          selected: {_pdfScrollDirection},
                          onSelectionChanged: (newSelection) {
                            setModalState(() {
                              _pdfScrollDirection = newSelection.first;
                            });
                            setState(() {});
                          },
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Text Selection Optimization Section
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          secondary: Icon(
                            Icons.text_format_rounded,
                            color: theme.colorScheme.primary,
                          ),
                          title: Text(L10n.of(context).msg176ef589, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          subtitle: const Text(
                            '关闭可显著提升页面渲染速度并消除滚动卡顿。',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _pdfEnableTextSelection,
                          activeColor: theme.colorScheme.primary,
                          onChanged: (val) {
                            setModalState(() {
                              _pdfEnableTextSelection = val;
                            });
                            setState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPresetButton({
    required BuildContext context,
    required String label,
    required String subtitle,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: isActive ? theme.colorScheme.primary : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      elevation: isActive ? 2 : 0,
      shadowColor: theme.colorScheme.primary.withOpacity(0.4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? Colors.transparent : theme.colorScheme.outline.withOpacity(0.2),
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: isActive ? theme.colorScheme.onPrimary.withOpacity(0.8) : theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTuningOption({
    required BuildContext context,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }

  IconData get _fileIcon {
    switch (_ext) {
      case '.pdf':
        return Broken.document;
      case '.doc':
      case '.docx':
        return Broken.document_text;
      case '.xls':
      case '.xlsx':
        return Broken.document_text;
      case '.ppt':
      case '.pptx':
        return Broken.presention_chart;
      case '.txt':
      case '.md':
        return Broken.note_2;
      default:
        return Broken.document;
    }
  }

  Color get _fileColor {
    switch (_ext) {
      case '.pdf':
        return Colors.redAccent;
      case '.doc':
      case '.docx':
        return Colors.blueAccent;
      case '.xls':
      case '.xlsx':
        return Colors.green;
      case '.ppt':
      case '.pptx':
        return Colors.orangeAccent;
      case '.txt':
      case '.md':
        return Colors.purpleAccent;
      default:
        return Colors.teal;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          _fileName,
          style: const TextStyle(fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_isText) ...[
            if (_isEditing) ...[
              if (_isSaving)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                IconButton(
                  icon: const Icon(Icons.undo_rounded),
                  onPressed: () {
                    if (_undoStack.isNotEmpty) {
                      setState(() {
                        _textController.text = _undoStack.removeLast();
                      });
                    }
                  },
                  tooltip: '撤销',
                ),
                IconButton(
                  icon: const Icon(Icons.save_rounded),
                  onPressed: _saveFile,
                  tooltip: '保存',
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _isEditing = false;
                      _textController.text = _textContent;
                    });
                  },
                  tooltip: '取消',
                ),
              ],
            ] else
              IconButton(
                icon: const Icon(Icons.note_add_rounded),
                onPressed: _createNewFile,
                tooltip: L10n.of(context).msgd28847a2,
              ),
          ],
          if (_isPdf)
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: _showPdfSettings,
              tooltip: '显示设置',
            ),
          if (_isText)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: L10n.of(context).msg3007c452,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              position: PopupMenuPosition.under,
              elevation: 8,
              onSelected: (value) {
                if (value == 'wrap') {
                  setState(() => _wordWrap = !_wordWrap);
                } else if (value == 'line_numbers') {
                  setState(() => _showLineNumbers = !_showLineNumbers);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'wrap',
                  child: Row(children: [
                    Icon(_wordWrap ? Icons.check_box_rounded : Icons.check_box_outline_blank, size: 20),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).msg452dba7c, style: TextStyle(fontWeight: FontWeight.w500)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'line_numbers',
                  child: Row(children: [
                    Icon(_showLineNumbers ? Icons.check_box_rounded : Icons.check_box_outline_blank, size: 20),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).msgc31f9440, style: TextStyle(fontWeight: FontWeight.w500)),
                  ]),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: _openExternal,
            tooltip: L10n.of(context).msg1d93c30b,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isText
              ? _buildTextViewer(theme, isDark)
              : _isWord
                  ? _buildWordViewer(theme, isDark)
                  : _isExcel
                      ? _buildExcelViewer(theme, isDark)
                      : _isPpt
                          ? _buildPptViewer(theme, isDark)
                          : _isPdf
                              ? _buildPdfViewer(theme, isDark)
                              : _buildDocumentPreview(theme, isDark),
    );
  }

  Widget _buildPdfViewer(ThemeData theme, bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
      child: SfPdfViewer.file(
        File(widget.filePath),
        canShowScrollHead: true,
        canShowScrollStatus: true,
        canShowPaginationDialog: true,
        pageLayoutMode: _pdfLayoutMode,
        scrollDirection: _pdfScrollDirection,
        enableTextSelection: _pdfEnableTextSelection,
      ),
    );
  }

  Widget _buildWordViewer(ThemeData theme, bool isDark) {
    if (_textContent.isEmpty) return _buildDocumentPreview(theme, isDark);

    return Container(
      color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.4 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: SelectableText(
            _textContent,
            style: TextStyle(
              fontSize: 15,
              height: 1.8,
              color: isDark ? Colors.white : const Color(0xFF2B2B36),
            ),
        ),
      ),
    ),
  );
}

  Widget _buildExcelViewer(ThemeData theme, bool isDark) {
    if (_excelSheets.isEmpty) return _buildDocumentPreview(theme, isDark);

    final rows = _excelSheets[_selectedSheet] ?? [];

    return Column(
      children: [
        if (_excelSheets.length > 1)
          Container(
            height: 50,
            color: theme.colorScheme.surface,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _excelSheets.keys.length,
              itemBuilder: (context, index) {
                final sheetName = _excelSheets.keys.elementAt(index);
                final isSelected = sheetName == _selectedSheet;
                return InkWell(
                  onTap: () => setState(() => _selectedSheet = sheetName),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: isSelected ? Colors.green : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                    child: Text(
                      sheetName,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.green : theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('空白表格'))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Table(
                        border: TableBorder.all(
                          color: theme.colorScheme.onSurface.withOpacity(0.2),
                          width: 1,
                        ),
                        defaultColumnWidth: const IntrinsicColumnWidth(),
                        children: rows.map((row) {
                          final isHeader = rows.indexOf(row) == 0;
                          return TableRow(
                            decoration: BoxDecoration(
                              color: isHeader
                                  ? Colors.green.withOpacity(0.15)
                                  : (rows.indexOf(row) % 2 == 0
                                      ? theme.colorScheme.surface.withOpacity(0.5)
                                      : Colors.transparent),
                            ),
                            children: row.map((cell) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Text(
                                  cell.toString(),
                                  style: TextStyle(
                                    fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
                                    fontSize: 13,
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPptViewer(ThemeData theme, bool isDark) {
    if (_pptSlides.isEmpty) return _buildDocumentPreview(theme, isDark);

    return Container(
      color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        itemCount: _pptSlides.length,
        itemBuilder: (context, index) {
          final slideText = _pptSlides[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 24),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.orangeAccent.withOpacity(0.3), width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.4 : 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '幻灯片 ${index + 1}',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                        fontSize: 12,
                      ),
                    ),
                    const Icon(Broken.presention_chart, color: Colors.orangeAccent, size: 20),
                  ],
                ),
                const Divider(height: 24),
                SelectableText(
                  slideText,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.6,
                    color: isDark ? Colors.white : const Color(0xFF2B2B36),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTextViewer(ThemeData theme, bool isDark) {
    final textStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      color: isDark ? Colors.white70 : Colors.black87,
      height: 1.6,
    );
    final lineNumberStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      color: isDark ? Colors.white38 : Colors.black38,
      height: 1.6,
    );

    if (_isEditing) {
      Widget textField = TextField(
        controller: _textController,
        focusNode: _textFieldFocusNode,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: textStyle.copyWith(height: null),
        strutStyle: StrutStyle(height: 1.6, fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          border: InputBorder.none,
          filled: true,
          fillColor: isDark ? const Color(0xFF121220) : Colors.white,
          contentPadding: const EdgeInsets.all(16),
        ),
        );

      // 自动换行：不换行时用水平滚动包裹
      if (!_wordWrap) {
        textField = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: double.infinity),
            child: IntrinsicHeight(child: textField),
          ),
        );
      }

      // 行号
      if (_showLineNumbers) {
        final lineCount = '\n'.allMatches(_textController.text).length + 1;
        final lineNumberWidth = lineCount.toString().length * 10.0 + 24;

        return Container(
          color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: lineNumberWidth,
                child: ListView.builder(
                  itemCount: lineCount,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 16, right: 8),
                  itemBuilder: (context, index) {
                    return Text(
                      '${index + 1}',
                      style: lineNumberStyle,
                      textAlign: TextAlign.right,
                    );
                  },
                ),
              ),
              Expanded(child: textField),
            ],
          ),
        );
      }

      return Container(
        color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
        padding: const EdgeInsets.all(12),
        child: textField,
      );
    }

    // 只读模式
    final textContent = _textController.text.isEmpty ? L10n.of(context).msgace80573 : _textController.text;

    Widget textWidget = SelectableText(
      textContent,
      style: textStyle,
      );

    // 只读模式自动换行
    if (!_wordWrap) {
      textWidget = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: double.infinity),
          child: IntrinsicWidth(child: textWidget),
        ),
      );
    }

    // 只读模式行号
    if (_showLineNumbers) {
      final lineCount = '\n'.allMatches(textContent).length + 1;
      final lineNumberWidth = lineCount.toString().length * 10.0 + 24;

      return Container(
        color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: lineNumberWidth,
                child: Column(
                  children: List.generate(lineCount, (index) {
                    return Text(
                      '${index + 1}',
                      style: lineNumberStyle,
                      textAlign: TextAlign.right,
                    );
                  }),
                ),
              ),
              Expanded(child: textWidget),
            ],
          ),
        ),
      );
    }

    return Container(
      color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: textWidget,
      ),
    );
  }

  Widget _buildDocumentPreview(ThemeData theme, bool isDark) {
    final fileColor = _fileColor;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 140,
            decoration: BoxDecoration(
              color: fileColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: fileColor.withOpacity(0.3), width: 1.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_fileIcon, color: fileColor, size: 48),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: fileColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _ext.toUpperCase().replaceAll('.', ''),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            _fileName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          FutureBuilder<FileStat>(
            future: FileStat.stat(widget.filePath),
            builder: (context, snap) {
              if (snap.hasData) {
                final size = snap.data!.size;
                final sizeStr = size < 1024
                    ? '$size B'
                    : size < 1024 * 1024
                        ? '${(size / 1024).toStringAsFixed(1)} KB'
                        : '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
                return Text(
                  sizeStr,
                  style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.5),
                    fontSize: 13,
                  ),
                );
              }
              return const SizedBox();
            },
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(L10n.of(context).msg030f48bd),
              style: FilledButton.styleFrom(
                backgroundColor: fileColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _openExternal,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: Icon(Icons.share, color: fileColor),
              label: Text(L10n.of(context).ui_share, style: TextStyle(color: fileColor)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: fileColor.withOpacity(0.5)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(L10n.of(context).msgfd96af00)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
