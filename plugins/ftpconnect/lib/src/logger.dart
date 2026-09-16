class Logger {
  final bool isEnabled;

  Logger({this.isEnabled = false});

  void log(String pMessage) {
    if (isEnabled) _printLog(pMessage);
  }

  void _printLog(String pMessage) {
    print('[${DateTime.now().toString()}] $pMessage');
  }
}
