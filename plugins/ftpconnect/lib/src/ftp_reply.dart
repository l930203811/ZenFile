import 'dart:core';

class FTPReply {
  final int _code;
  final String _messages;

  FTPReply(this._code, this._messages);

  get code => _code;

  get message => _messages;

  bool isSuccessCode() {
    int aux = _code - 200;
    return aux >= 0 && aux < 100;
  }

  @override
  String toString() {
    StringBuffer buffer = StringBuffer();
    buffer.write("FTPReply =  [code= $_code, message= $_messages]");
    return buffer.toString();
  }
}
