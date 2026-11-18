import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:excel/excel.dart' as excel_pkg;
import 'package:excel2003/excel2003.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:xml/xml.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../services/preferences_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:zenfile/ui/widgets/native_pdf_viewer.dart';

/// ── 办公文档（xlsx / xls / docx / pptx）查看的 ANR 防护（issue #78） ──
///
/// 崩溃取证：OnePlus / Android 16，v3.7.9 打开 xlsx 后主线程在 libapp.so 深栈
/// 烧 CPU > 5s（输入分发超时 ANR），进程 RSS ~1.9GB。根因有三层：
/// ① `Excel.decodeBytes` + 全表遍历在**主 isolate** 同步执行（纯 CPU）；
/// ② 渲染层用 `Table` + `IntrinsicColumnWidth` 一次性构建**全部行 × 全部列**
///    的 widget（不虚拟化），行多时即使解析挪到后台，构建一帧同样占死主线程；
/// ③ 所有 sheet 全量转字符串常驻内存（RSS 爆高的元凶）。
///
/// 对策：
/// * 解析全部移入后台 isolate（见下方 `_parseXxxIsolate` 顶层函数）；
/// * 解析层限行/限列（内存上限可控），渲染层限行（每帧构建成本可控）；
/// * 超大文件（> [kDocOfficeInlineSafeBytes]，与 PDF 同一阈值）不再内置解析，
///   直接回退到「文档预览 + 外部应用打开」页。
const int kDocOfficeInlineSafeBytes = 20 * 1024 * 1024;

/// 解析层：每个 sheet 最多读入的行数（超出部分不解析、不入内存）。
const int kDocSheetMaxParseRows = 5000;

/// 解析层：每个 sheet 最多读入的列数。
const int kDocSheetMaxParseCols = 100;

/// 渲染层：表格预览最多构建的行数（`Table` 不虚拟化，行数直接决定单帧成本）。
const int kDocSheetPreviewRows = 100;

/// xlsx（OOXML）解析：在后台 isolate 执行，返回「sheet 名 → 字符串网格」。
Map<String, List<List<String>>> _parseXlsxIsolate(Uint8List bytes) {
  final excel = excel_pkg.Excel.decodeBytes(bytes);
  final out = <String, List<List<String>>>{};
  for (final table in excel.tables.keys) {
    final sheet = excel.tables[table]!;
    final rows = <List<String>>[];
    for (final row in sheet.rows) {
      if (rows.length >= kDocSheetMaxParseRows) break;
      final rowData = <String>[];
      final cols = row.length < kDocSheetMaxParseCols
          ? row.length
          : kDocSheetMaxParseCols;
      for (var i = 0; i < cols; i++) {
        rowData.add(row[i]?.value?.toString() ?? '');
      }
      rows.add(rowData);
    }
    out[table] = rows;
  }
  return out;
}

/// xls（BIFF 2-8 二进制格式）解析：在后台 isolate 执行。
Map<String, List<List<String>>> _parseXlsIsolate(Uint8List bytes) {
  final xls = XlsReader.fromBytes(bytes);
  final out = <String, List<List<String>>>{};
  for (final sheetName in xls.sheetNames) {
    final sheet = xls.sheetByName(sheetName);
    if (sheet == null) continue;
    final rows = <List<String>>[];
    for (final r in sheet.rows) {
      if (rows.length >= kDocSheetMaxParseRows) break;
      final rowData = <String>[];
      final cols = r.length < kDocSheetMaxParseCols
          ? r.length
          : kDocSheetMaxParseCols;
      for (var i = 0; i < cols; i++) {
        rowData.add(r[i]?.toString() ?? '');
      }
      rows.add(rowData);
    }
    out[sheetName] = rows;
  }
  return out;
}

/// docx 正文抽取：在后台 isolate 执行。
String _parseDocxIsolate(Uint8List bytes) => docxToText(bytes);

/// pptx 幻灯片文本抽取：在后台 isolate 执行（zip 解包 + 逐页 XML 解析）。
/// 空页返回空字符串，由调用方（主 isolate）填本地化文案。
List<String> _parsePptxIsolate(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final slideMap = <int, String>{};
  for (final file in archive.files) {
    if (file.name.startsWith('ppt/slides/slide') &&
        file.name.endsWith('.xml')) {
      final match = RegExp(r'slide(\d+)\.xml').firstMatch(file.name);
      if (match != null) {
        final slideNum = int.parse(match.group(1)!);
        final contentStr = utf8.decode(file.content as List<int>);
        final doc = XmlDocument.parse(contentStr);
        final textNodes = doc.findAllElements('a:t');
        slideMap[slideNum] = textNodes
            .map((node) => node.innerText)
            .where((t) => t.trim().isNotEmpty)
            .join('\n');
      }
    }
  }
  final sortedKeys = slideMap.keys.toList()..sort();
  return sortedKeys.map((k) => slideMap[k]!).toList();
}

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
  final Map<String, List<List<String>>> _excelSheets = {};
  String _selectedSheet = '';
  List<String> _pptSlides = [];

  /// Office 文档体积探测（xlsx / xls / docx / pptx，见 [kDocOfficeInlineSafeBytes]）。
  int? _officeFileBytes;
  bool _officeProbeDone = false;

  /// 超大 Office 文件不做内置解析（解析再快也会撑爆内存与首帧），直接走
  /// 「文档预览 + 外部应用打开」兜底页（各 viewer 在数据为空时自动显示该页）。
  bool get _officeTooLarge =>
      _officeProbeDone &&
      (_isExcel || _isWord || _isPpt) &&
      (_officeFileBytes ?? 0) > kDocOfficeInlineSafeBytes;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEditing = false;
  /// 「自动换行 / 显示行号」是**用户显示偏好**，与编辑/阅读模式无关：
  /// 默认换行开、行号关，且持久化（与文本编辑器共用同两个偏好键）。
  bool _wordWrap = PreferencesService.getEditorWordWrap();
  bool _showLineNumbers = PreferencesService.getEditorShowLineNumbers();
  late TextEditingController _textController;
  final FocusNode _textFieldFocusNode = FocusNode();
  final List<String> _undoStack = [];

  PdfPageLayoutMode _pdfLayoutMode = PdfPageLayoutMode.continuous;
  PdfScrollDirection _pdfScrollDirection = PdfScrollDirection.vertical;
  bool _pdfEnableTextSelection = true;

  int _pdfViewerVersion = 0;

  /// 内置 PDF 查看器（Syncfusion）**在主 isolate 上同步解析整份文档**，并且会把
  /// 整个文件一次性读进内存：
  /// * 字节源走 `getBytes()`（整文件读成 `Uint8List`）；
  /// * 解析是纯 Dart 的 `PdfDocument(inputBytes: ...)`，**没有**放进 isolate
  ///   （该包只为「解密 / 文本搜索」建 isolate，解析与页面渲染都在 UI 线程）。
  ///
  /// 于是文件越大，主线程被占死越久 —— 一旦超过输入分发超时（约 5s），系统就判定
  /// ANR，用户看到「无响应」后关掉应用，表现为「打开大 PDF 就闪退」。崩溃取证里
  /// 类型正是 ANR（原因码 6），main 线程 state=R 在 Dart 代码里持续烧 CPU。
  /// 体积再大还会因整份字节常驻堆内存（本机堆上限仅 256MB）而 OOM。
  ///
  /// 因此超过此体积时**不再用 Syncfusion 直接渲染**（否则必 ANR），而是直接走
  /// 原生 PdfRenderer 兜底查看器（后台线程分页渲染，不卡 UI，见 NativePdfViewer）。
  /// 不再弹「用其他应用打开 / 仍要尝试」的提示选择框，大文件打开即进兜底查看器。
  static const int _kPdfInlineSafeBytes = 20 * 1024 * 1024;

  /// PDF 体积（探测失败时为 null）。
  int? _pdfFileBytes;

  /// 体积探测是否完成 —— 完成前不构建查看器，避免「探测还没回来就先开解析」。
  bool _pdfProbeDone = false;

  /// 超过安全体积时，内置 Syncfusion 查看器会因同步解析占死主线程 → ANR。
  /// 这类文件一律走原生 PdfRenderer 兜底查看器（后台线程分页渲染，不卡 UI）。
  bool get _shouldUseNativePdf =>
      _isPdf && _pdfProbeDone && (_pdfFileBytes ?? 0) > _kPdfInlineSafeBytes;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    if (_isPdf) {
      _probePdfSize();
    } else if (_isText) {
      _loadTextFile();
    } else if (_isWord) {
      _probeOfficeSizeThen(_loadWordFile);
    } else if (_isExcel) {
      _probeOfficeSizeThen(_loadExcelFile);
    } else if (_isPpt) {
      _probeOfficeSizeThen(_loadPptFile);
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

  /// 打开前先取 PDF 体积（`File.length()` 是异步 IO，不占主线程），
  /// 用它决定要不要直接构建内置查看器（见 [_kPdfInlineSafeBytes]）。
  Future<void> _probePdfSize() async {
    int? size;
    try {
      final file = File(widget.filePath);
      if (await file.exists()) size = await file.length();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _pdfFileBytes = size;
      _pdfProbeDone = true;
      _isLoading = false;
    });
  }

  /// 先探测 Office 文档体积，超大文件直接跳过解析（显示预览兜底页），
  /// 正常体积的文件再执行 [load]。
  Future<void> _probeOfficeSizeThen(Future<void> Function() load) async {
    int? size;
    try {
      final file = File(widget.filePath);
      if (await file.exists()) size = await file.length();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _officeFileBytes = size;
      _officeProbeDone = true;
    });
    if (_officeTooLarge) {
      setState(() => _isLoading = false);
      return;
    }
    await load();
  }

  Future<void> _loadTextFile() async {
    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        // 大文本（>512KB）的多编码回退解码是 CPU 密集操作：大 log / csv 在主
        // isolate 上解码同样会占死主线程（与 issue #78 同类问题），移入后台。
        final String content = bytes.length > 512 * 1024
            ? await compute(_decodeBytesWithFallback, bytes)
            : _decodeBytesWithFallback(bytes);
        _textController.text = content;
        _textContent = content;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).e11(e))),
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
      // docx 解包 + XML 文本抽取移入后台 isolate（与 issue #78 同类问题）。
      final text = await compute(_parseDocxIsolate, bytes);
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
      if (_officeTooLarge) return;
      final file = File(widget.filePath);
      final bytes = await file.readAsBytes();

      // 解析（zip 解包 + sheet 遍历 + 单元格转字符串）全部移入后台 isolate：
      // 主 isolate 上执行时，大表格会把主线程占死数秒甚至数十秒 → 输入分发
      // 超时 ANR（issue #78）。解析层已限行/限列，内存上限可控。
      final sheets = _ext == '.xls'
          ? await compute(_parseXlsIsolate, bytes)
          : await compute(_parseXlsxIsolate, bytes);

      _excelSheets
        ..clear()
        ..addAll(sheets);

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
      // zip 解包 + 逐页 XML 解析移入后台 isolate（与 issue #78 同类问题）；
      // isolate 内不能用 context，空页文案在主 isolate 侧补本地化。
      final slides = await compute(_parsePptxIsolate, bytes);
      if (!mounted) return;
      final emptyLabel = L10n.of(context).msg5937f822;
      _pptSlides =
          slides.map((s) => s.isEmpty ? emptyLabel : s).toList();
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
          SnackBar(
            content: Text(L10n.of(context).msg360d0b37),
            duration: const Duration(seconds: 2),
          ),
        );
        setState(() => _isEditing = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).e9(e))),
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
                    color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
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
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
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
                            icon: Icon(Icons.close_rounded, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L10n.of(context).msg09c933bf,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Quick Tuning Presets
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.of(context).msg_pdf_quick_presets,
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
                                    label: L10n.of(context).msg_pdf_smooth_mode,
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
                        L10n.of(context).msg_pdf_detail_tuning,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),

                      // Page Layout Option
                      _buildTuningOption(
                        context: context,
                        title: L10n.of(context).msg8b519c02,
                        subtitle: _pdfLayoutMode == PdfPageLayoutMode.continuous
                            ? L10n.of(context).msg7f2cd152
                            : L10n.of(context).msg_pdf_single_page_scroll,
                        child: SegmentedButton<PdfPageLayoutMode>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            selectedBackgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                            selectedForegroundColor: theme.colorScheme.primary,
                          ),
                          segments: [
                            ButtonSegment<PdfPageLayoutMode>(
                              value: PdfPageLayoutMode.continuous,
                              icon: const Icon(Icons.view_day_outlined, size: 18),
                              label: Text(L10n.of(context).msg_pdf_continuous),
                            ),
                            ButtonSegment<PdfPageLayoutMode>(
                              value: PdfPageLayoutMode.single,
                              icon: const Icon(Icons.auto_stories_outlined, size: 18),
                              label: Text(L10n.of(context).msg_pdf_single_page),
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
                            : L10n.of(context).msg_pdf_horizontal_scroll,
                        child: SegmentedButton<PdfScrollDirection>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            selectedBackgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                            selectedForegroundColor: theme.colorScheme.primary,
                          ),
                          segments: [
                            ButtonSegment<PdfScrollDirection>(
                              value: PdfScrollDirection.vertical,
                              icon: const Icon(Icons.swap_vert_rounded, size: 18),
                              label: Text(L10n.of(context).msg_pdf_vertical),
                            ),
                            ButtonSegment<PdfScrollDirection>(
                              value: PdfScrollDirection.horizontal,
                              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                              label: Text(L10n.of(context).msg_pdf_horizontal),
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
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          secondary: Icon(
                            Icons.text_format_rounded,
                            color: theme.colorScheme.primary,
                          ),
                          title: Text(L10n.of(context).msg176ef589, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          subtitle: Text(
                            L10n.of(context).msg864f8706,
                            style: const TextStyle(fontSize: 12),
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
      shadowColor: theme.colorScheme.primary.withValues(alpha: 0.4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? Colors.transparent : theme.colorScheme.outline.withValues(alpha: 0.2),
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
                  color: isActive ? theme.colorScheme.onPrimary.withValues(alpha: 0.8) : theme.colorScheme.onSurface.withValues(alpha: 0.6),
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
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
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

    return PopScope(
      canPop: true,
      child: Scaffold(
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
                  tooltip: L10n.of(context).ui_undo,
                ),
                IconButton(
                  icon: const Icon(Icons.save_rounded),
                  onPressed: _saveFile,
                  tooltip: L10n.of(context).ui_save,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _isEditing = false;
                      _textController.text = _textContent;
                    });
                  },
                  tooltip: L10n.of(context).ui_cancel,
                ),
              ],
            ] else
              IconButton(
                icon: const Icon(Icons.note_add_rounded),
                onPressed: _createNewFile,
                tooltip: L10n.of(context).msgd28847a2,
              ),
          ],
          // 原生兜底查看器（大文件）与提示页都没有「显示设置」的意义，一并隐去。
          if (_isPdf && !_shouldUseNativePdf)
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: _showPdfSettings,
              tooltip: L10n.of(context).display_settings,
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
                  PreferencesService.saveEditorWordWrap(_wordWrap);
                } else if (value == 'line_numbers') {
                  setState(() => _showLineNumbers = !_showLineNumbers);
                  PreferencesService.saveEditorShowLineNumbers(_showLineNumbers);
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
      ),
    );
  }

  Widget _buildPdfViewer(ThemeData theme, bool isDark) {
    // 体积还没探测出来就先转圈：不能让「探测结果未知」的文档先进解析器。
    if (!_pdfProbeDone) {
      return const Center(child: CircularProgressIndicator());
    }
    // 大文件（>20MB）：直接走原生 PdfRenderer 兜底查看器（后台线程分页渲染），
    // 不再用 Syncfusion 在 UI isolate 同步解析，避免主线程被占死 → ANR。
    // 此处不再弹提示选择框，大文件打开即进兜底查看器。
    if (_shouldUseNativePdf) {
      return NativePdfViewer(
        filePath: widget.filePath,
        onOpenExternal: _openExternal,
      );
    }
    return Container(
      color: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
      child: SfPdfViewer.file(
        File(widget.filePath),
        key: ValueKey(_pdfViewerVersion),
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
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
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
    final previewRows = rows.length > kDocSheetPreviewRows
        ? rows.sublist(0, kDocSheetPreviewRows)
        : rows;
    final rowsTruncated = rows.length > previewRows.length;

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
                        color: isSelected ? Colors.green : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(L10n.of(context).empty_table))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      // 渲染层限行（issue #78）：`Table` 不虚拟化，行数直接决定
                      // 单帧构建成本 —— IntrinsicColumnWidth 会测量每个单元格，
                      // 全量渲染上万行会在主 isolate 上构建出秒级长帧（ANR）。
                      // 超出部分不渲染，用底部提示引导走外部应用查看完整内容。
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Table(
                            border: TableBorder.all(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                              width: 1,
                            ),
                            defaultColumnWidth: const IntrinsicColumnWidth(),
                            children: [
                              for (var i = 0; i < previewRows.length; i++)
                                TableRow(
                                  decoration: BoxDecoration(
                                    color: i == 0
                                        ? Colors.green.withValues(alpha: 0.15)
                                        : (i % 2 == 0
                                            ? theme.colorScheme.surface.withValues(alpha: 0.5)
                                            : Colors.transparent),
                                  ),
                                  children: previewRows[i].map((cell) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      child: Text(
                                        cell.toString(),
                                        style: TextStyle(
                                          fontWeight: i == 0 ? FontWeight.bold : FontWeight.normal,
                                          fontSize: 13,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                            ],
                          ),
                          if (rowsTruncated) ...[
                            const SizedBox(height: 12),
                            Text(
                              L10n.of(context).docSheetPreviewTruncated(
                                kDocSheetPreviewRows,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                              ),
                            ),
                          ],
                        ],
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
              border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3), width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
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
              color: fileColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: fileColor.withValues(alpha: 0.3), width: 1.5),
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
                        theme.colorScheme.onSurface.withValues(alpha: 0.5),
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
                side: BorderSide(color: fileColor.withValues(alpha: 0.5)),
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
