// ignore_for_file: deprecated_member_use

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'webdav_debug_log.dart';
import 'startup_gate.dart';

class ZenFileBinding extends WidgetsFlutterBinding {
  static WidgetsBinding ensureInitialized() => ZenFileBinding();

  @override
  BinaryMessenger createBinaryMessenger() {
    return InputTraceMessenger(super.createBinaryMessenger());
  }
}

class InputTraceMessenger extends BinaryMessenger {
  InputTraceMessenger(this.delegate);

  final BinaryMessenger delegate;
  static const JSONMethodCodec _codec = JSONMethodCodec();
  static int _textInputSequence = 0;

  void verifyInstalled() {
    WebdavDebugLog.logAlways(
      '[input] BinaryMessenger=$runtimeType '
      'delegate=${delegate.runtimeType} channels=navigation,textInput codec=JSON',
    );
  }

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    _trace(channel, message, incoming: false);
    return delegate.send(channel, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    if (handler == null) {
      delegate.setMessageHandler(channel, null);
      return;
    }
    delegate.setMessageHandler(channel, (ByteData? message) {
      _trace(channel, message, incoming: true);
      return handler(message);
    });
  }

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) {
    _trace(channel, data, incoming: true);
    return delegate.handlePlatformMessage(channel, data, callback);
  }

  static void _trace(String channel, ByteData? data, {required bool incoming}) {
    try {
      if (channel == SystemChannels.textInput.name) {
        _traceTextInput(data, incoming: incoming);
      } else if (channel == SystemChannels.navigation.name) {
        final call = _decode(data);
        if (call != null) {
          WebdavDebugLog.logAlways(
            '[input] 导航通道 ${incoming ? '收到' : '发出'} ${call.method}',
          );
          if (!incoming && call.method == 'SystemNavigator.pop') {
            WebdavDebugLog.logAlways(
              '[input] SystemNavigator.pop 调用来源\n${StackTrace.current}',
            );
          }
        }
      }
    } catch (_) {
      // 诊断绝不能影响平台消息。
    }
  }

  static MethodCall? _decode(ByteData? data) {
    if (data == null) return null;
    try {
      // 平台消息体是 encodeMethodCall() 的编码（[方法名, 参数]），必须用
      // decodeMethodCall 解码；decodeEnvelope 是给「方法调用的返回值」
      // （[success, result]）用的。用错 API 会把每条 TextInput 请求
      // 静默吞掉，导致 [input] 文本 序列一条都写不出来（2026-11-29 实测）。
      // textInput / navigation 两个通道都用 JSONMethodCodec（见 system_channels.dart）。
      return _codec.decodeMethodCall(data);
    } catch (_) {
      return null;
    }
  }

  static void _traceTextInput(ByteData? data, {required bool incoming}) {
    final call = _decode(data);
    if (call == null) return;
    if (incoming) StartupGate.instance.noteInput();
    final direction = incoming ? '收到' : '发出';
    final sequence = ++_textInputSequence;
    switch (call.method) {
      case 'TextInput.setClient':
        final args = call.arguments;
        if (args is List && args.isNotEmpty) {
          WebdavDebugLog.logAlways(
            '[input] 文本 $direction ${call.method} 序列=#$sequence '
            'client=${args.first}',
          );
        }
      // ⚠️ 方法名必须是 `TextInputClient.updateEditingState`（不是
      // `TextInput.updateEditingState`）—— 见 flutter text_input.dart 的
      // `_handleTextInputCall` switch。写成后者会让每次按键都落进 default
      // 分支，日志里只剩方法名、看不到字符数和选区（2026-11-29 实测）。
      case 'TextInputClient.updateEditingState':
      case 'TextInputClient.updateEditingStateWithDeltas':
      case 'TextInput.updateEditingState':
      case 'TextInput.setEditingState':
        final args = call.arguments;
        if (args is List && args.length >= 2) {
          WebdavDebugLog.logAlways(
            '[input] 文本 $direction ${call.method} 序列=#$sequence '
            'client=${args[0]} ${_describeEditingValue(args[1])}',
          );
        } else {
          WebdavDebugLog.logAlways(
            '[input] 文本 $direction ${call.method} 序列=#$sequence '
            '参数异常=${args.runtimeType}',
          );
        }
      case 'TextInputClient.performAction':
      case 'TextInput.performAction':
        final args = call.arguments;
        if (args is List && args.length >= 2) {
          WebdavDebugLog.logAlways(
            '[input] 文本 $direction ${call.method} 序列=#$sequence '
            'client=${args[0]} action=${args[1]}',
          );
        }
      default:
        WebdavDebugLog.logAlways(
          '[input] 文本 $direction ${call.method} 序列=#$sequence',
        );
    }
  }

  static String _describeEditingValue(Object? value) {
    if (value is! Map) return '状态=未知';
    final text = value['text'];
    final selection = value['selection'];
    final composing = value['composing'];
    return '字符=${text is String ? text.runes.length : '?'} '
        '选区=${_describeRange(selection)} 组合=${_describeRange(composing)}';
  }

  static String _describeRange(Object? value) {
    if (value is! Map) return '-';
    final base = value['base'];
    final extent = value['extent'];
    return '${base is int ? base : '?'}..${extent is int ? extent : '?'}';
  }
}
