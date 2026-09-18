import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/decibel_meter_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 分贝仪页面：通过麦克风实时采集环境音量，
/// 以半圆表盘（绿/黄/红）+ 实时噪声曲线展示当前分贝值。
class DecibelMeterScreen extends StatefulWidget {
  const DecibelMeterScreen({super.key});

  @override
  State<DecibelMeterScreen> createState() => _DecibelMeterScreenState();
}

class _DecibelMeterScreenState extends State<DecibelMeterScreen>
    with SingleTickerProviderStateMixin {
  final DecibelMeterService _service = DecibelMeterService();
  Timer? _ticker;
  double _currentDb = 0;
  final List<double> _history = <double>[]; // 最近约 30 秒的噪声曲线
  bool _isMeasuring = false;
  String? _errorMsg;
  AnimationController? _animCtrl;
  double _smoothDb = 0; // 平滑后的指针值（避免指针跳动过快）

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _service.onData = _onData;
    // 打开页面即主动请求麦克风权限
    _requestMicrophonePermission();
  }

  Future<void> _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (status.isGranted) {
      return;
    }
    if (status.isPermanentlyDenied) {
      setState(() {
        _errorMsg = _permDeniedMsg();
      });
      _showSettingsDialog();
    } else {
      setState(() {
        _errorMsg = _permDeniedMsg();
      });
    }
  }

  String _permDeniedMsg() {
    return L10n.of(context).decibel_meter_perm_denied;
  }

  void _showSettingsDialog() {
    final l10n = L10n.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.decibel_meter_perm_title),
        content: Text(l10n.decibel_meter_perm_settings),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.ui_cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: Text(l10n.decibel_meter_perm_open_settings),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _service.stop();
    _animCtrl?.dispose();
    super.dispose();
  }

  void _onData(double db) {
    if (!mounted) return;
    setState(() {
      _currentDb = db;
      _history.add(db);
      if (_history.length > 180) _history.removeAt(0); // 180 个点 ≈ 60s @3/s
    });
    // 平滑指针动画
    _animCtrl?.animateTo(
      (db / 120).clamp(0.0, 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  Future<void> _toggleMeasure() async {
    if (_isMeasuring) {
      await _service.stop();
      _ticker?.cancel();
      if (mounted) {
        setState(() {
          _isMeasuring = false;
        });
      }
      return;
    }

    // 开始前再次确认麦克风权限
    final status = await Permission.microphone.status;
    if (!status.isGranted) {
      await _requestMicrophonePermission();
      final recheck = await Permission.microphone.status;
      if (!recheck.isGranted) return;
    }
    if (!mounted) return;

    final ok = await _service.start();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _errorMsg = _service.lastError ?? _permDeniedMsg();
      });
      return;
    }
    setState(() {
      _isMeasuring = true;
      _errorMsg = null;
      _history.clear();
      _currentDb = 0;
      _smoothDb = 0;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 333), (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.decibel_meter_title),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // 权限/错误提示条
                  if (_errorMsg != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.error.withOpacity(0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 20,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorMsg!,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 半圆表盘
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        _buildGauge(theme),
                        const SizedBox(height: 12),
                        // 当前分贝值 + 环境判定
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildValueItem(
                              l10n.decibel_meter_current,
                              '${_currentDb.toStringAsFixed(1)} dB',
                              theme,
                            ),
                            _buildValueItem(
                              l10n.decibel_meter_verdict,
                              _verdictLabel(l10n),
                              theme,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 噪声曲线
                  _buildNoiseChart(theme, l10n),
                  const SizedBox(height: 16),
                  // 说明卡片
                  _buildInfoCard(theme, l10n),
                ],
              ),
            ),
          ),
          // 底部停止/开始按钮
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _toggleMeasure,
                  style: FilledButton.styleFrom(
                    backgroundColor: _isMeasuring
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  icon: Icon(
                    _isMeasuring ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 22,
                  ),
                  label: Text(
                    _isMeasuring
                        ? l10n.decibel_meter_stop
                        : l10n.decibel_meter_start,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 半圆分贝表盘：绿(0-60) 黄(60-90) 红(90-120) 三区 + 指针
  Widget _buildGauge(ThemeData theme) {
    return AnimatedBuilder(
      animation: _animCtrl!,
      builder: (context, _) {
        final pointerValue = _animCtrl!.value * 120;
        return CustomPaint(
          size: const Size(280, 160),
          painter: _GaugePainter(
            value: pointerValue,
            greenColor: Colors.green.shade500,
            yellowColor: Colors.amber.shade600,
            redColor: Colors.red.shade500,
            tickColor: theme.colorScheme.onSurface.withOpacity(0.4),
            textColor: theme.colorScheme.onSurface,
            valueTextColor: theme.colorScheme.onSurface,
          ),
        );
      },
    );
  }

  Widget _buildValueItem(String label, String value, ThemeData theme) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: theme.colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  String _verdictLabel(L10n l10n) {
    final db = _currentDb;
    if (db < 30) return l10n.decibel_meter_level_quiet;
    if (db < 60) return l10n.decibel_meter_level_normal;
    if (db < 80) return l10n.decibel_meter_level_noisy;
    if (db < 100) return l10n.decibel_meter_level_very_noisy;
    return l10n.decibel_meter_level_dangerous;
  }

  /// 实时噪声曲线图（Y 轴 0-120 dB）
  Widget _buildNoiseChart(ThemeData theme, L10n l10n) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.onSurface.withOpacity(0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.decibel_meter_curve,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 140,
            width: double.infinity,
            child: CustomPaint(
              painter: _NoiseChartPainter(
                history: _history,
                lineColor: theme.colorScheme.primary,
                gridColor: theme.colorScheme.onSurface.withOpacity(0.1),
                textColor: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 说明卡片：对人体影响 + 常见场景举例
  Widget _buildInfoCard(ThemeData theme, L10n l10n) {
    final db = _currentDb;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.onSurface.withOpacity(0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${l10n.decibel_meter_health_impact}: '
                  '${_healthImpactLabel(l10n, db)}',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.volume_up_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${l10n.decibel_meter_examples}: '
                  '${_examplesLabel(l10n, db)}',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _healthImpactLabel(L10n l10n, double db) {
    if (db < 60) return l10n.decibel_meter_health_safe;
    if (db < 80) return l10n.decibel_meter_health_moderate;
    if (db < 100) return l10n.decibel_meter_health_harmful;
    return l10n.decibel_meter_health_dangerous;
  }

  /// 按当前分贝值返回对应档位的常见场景举例文案（与健康影响档位一致）。
  String _examplesLabel(L10n l10n, double db) {
    if (db < 60) return l10n.decibel_meter_examples_safe;
    if (db < 80) return l10n.decibel_meter_examples_moderate;
    if (db < 100) return l10n.decibel_meter_examples_harmful;
    return l10n.decibel_meter_examples_dangerous;
  }
}

/// 半圆表盘绘制器
class _GaugePainter extends CustomPainter {
  final double value;
  final Color greenColor;
  final Color yellowColor;
  final Color redColor;
  final Color tickColor;
  final Color textColor;
  final Color valueTextColor;

  _GaugePainter({
    required this.value,
    required this.greenColor,
    required this.yellowColor,
    required this.redColor,
    required this.tickColor,
    required this.textColor,
    required this.valueTextColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    final radius = math.min(size.width / 2 - 20, size.height - 20);
    final startAngle = math.pi; // 180°（左）
    final sweep = math.pi; // 半圆

    // 背景弧
    final bgRect = Rect.fromCircle(center: center, radius: radius);
    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = Colors.grey.withOpacity(0.15);
    canvas.drawArc(bgRect, startAngle, sweep, false, bgPaint);

    // 三色区域：绿 0-60、黄 60-90、红 90-120
    void drawArc(double from, double to, Color color) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = color
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        bgRect,
        startAngle + sweep * (from / 120),
        sweep * ((to - from) / 120),
        false,
        paint,
      );
    }

    drawArc(0, 60, greenColor);
    drawArc(60, 90, yellowColor);
    drawArc(90, 120, redColor);

    // 刻度（0、20、40、60、80、100、120）
    for (var i = 0; i <= 6; i++) {
      final v = i * 20;
      final angle = startAngle + sweep * (v / 120);
      final outer = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      final inner =
          center + Offset(math.cos(angle), math.sin(angle)) * (radius - 8);
      final tickPaint = Paint()
        ..color = tickColor
        ..strokeWidth = 1.5;
      canvas.drawLine(inner, outer, tickPaint);

      // 刻度文字（0、40、80、120 显示）
      if (v % 40 == 0) {
        final textPos =
            center + Offset(math.cos(angle), math.sin(angle)) * (radius - 20);
        final tp = TextPainter(
          text: TextSpan(
            text: '$v',
            style: TextStyle(fontSize: 10, color: textColor),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          textPos - Offset(tp.width / 2, tp.height / 2),
        );
      }
    }

    // 指针
    final pointerAngle = startAngle + sweep * (value / 120).clamp(0.0, 1.0);
    final pointerLen = radius - 24;
    final pointerTip =
        center + Offset(math.cos(pointerAngle), math.sin(pointerAngle)) * pointerLen;
    final pointerPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, pointerTip, pointerPaint);

    // 中心圆点
    canvas.drawCircle(center, 6, Paint()..color = Colors.redAccent);

    // 中心数值
    final valueText = '${value.toStringAsFixed(1)}dB';
    final tp = TextPainter(
      text: TextSpan(
        text: valueText,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: valueTextColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      center - Offset(tp.width / 2, tp.height / 2 + 26),
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.value != value;
  }
}

/// 实时噪声曲线绘制器
class _NoiseChartPainter extends CustomPainter {
  final List<double> history;
  final Color lineColor;
  final Color gridColor;
  final Color textColor;

  _NoiseChartPainter({
    required this.history,
    required this.lineColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const maxDb = 120.0;
    const gridLines = 6; // 0,20,40,60,80,100,120

    // 网格 + Y 轴标签
    for (var i = 0; i <= gridLines; i++) {
      final db = maxDb - i * 20;
      final y = size.height * (i / gridLines);
      final gridPaint = Paint()
        ..color = gridColor
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: '${db.toInt()}',
          style: TextStyle(fontSize: 9, color: textColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - tp.height / 2));
    }

    if (history.length < 2) return;

    // 折线（X 从右向左滚动：最新的点在右侧）
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final step = size.width / 179;
    for (var i = 0; i < history.length; i++) {
      final x = size.width - (history.length - 1 - i) * step;
      final y = size.height - (history[i] / maxDb).clamp(0.0, 1.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _NoiseChartPainter oldDelegate) {
    return oldDelegate.history != history;
  }
}
