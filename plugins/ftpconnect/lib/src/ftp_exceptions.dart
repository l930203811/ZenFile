class FTPConnectException implements Exception {
  final String message;
  final String? response;

  FTPConnectException(this.message, [this.response]);

  @override
  String toString() {
    return 'FTPConnectException: $message (Response: $response)';
  }
}
