import 'dart:async';
import 'dart:io';

import 'package:path/path.dart';

import '../../ftpconnect.dart';
import '../ftp_reply.dart';
import '../ftp_socket.dart';
import '../utils.dart';

typedef FileProgress = void Function(
    double progressInPercent, int totalReceived, int fileSize);

class FTPFile {
  final FTPSocket _socket;

  FTPFile(this._socket);

  Future<bool> rename(String sOldName, String sNewName) async {
    FTPReply sResponse = await (_socket.sendCommand('RNFR $sOldName'));
    if (sResponse.code != 350) {
      return false;
    }

    sResponse = await (_socket.sendCommand('RNTO $sNewName'));
    return sResponse.isSuccessCode();
  }

  Future<bool> delete(String? sFilename) async {
    FTPReply sResponse = await (_socket.sendCommand('DELE $sFilename'));

    return sResponse.isSuccessCode();
  }

  Future<bool> exist(String sFilename) async {
    return await size(sFilename) != -1;
  }

  Future<int> size(String? sFilename) async {
    try {
      FTPReply sResponse = await (_socket.sendCommand('SIZE $sFilename'));
      if (!sResponse.isSuccessCode() &&
          _socket.transferType != TransferType.binary) {
        //check if ascii mode get refused
        //change to binary mode if ascii mode refused
        final socketTransferTypeBackup = _socket.transferType;
        await _socket.setTransferType(TransferType.binary);
        sResponse = await (_socket.sendCommand('SIZE $sFilename'));
        //back to default mode
        await _socket.setTransferType(socketTransferTypeBackup);
      }
      return int.parse(sResponse.message.replaceAll('213 ', ''));
    } catch (e) {
      return -1;
    }
  }

  Future<bool> download(
    String? sRemoteName,
    File fLocalFile, {
    FileProgress? onProgress,
  }) async {
    _socket.logger.log('Download $sRemoteName to ${fLocalFile.path}');
    //check for file existence and init totalData to receive
    int fileSize = 0;
    fileSize = await FTPFile(_socket).size(sRemoteName);
    if (fileSize == -1) {
      throw FTPConnectException('Remote File $sRemoteName does not exist!');
    }

    // Enter passive mode
    FTPReply response = await _socket.openDataTransferChannel();

    //the response will be the file, witch will be loaded with another socket
    _socket.sendCommandWithoutWaitingResponse('RETR $sRemoteName');

    // Data Transfer Socket
    int lPort = Utils.parsePort(response.message, _socket.supportIPV6);
    _socket.logger.log('Opening DataSocket to Port $lPort');
    final Socket dataSocket = await Socket.connect(_socket.host, lPort,
        timeout: Duration(seconds: _socket.timeout));
    // Test if second socket connection accepted or not
    response = await _socket.readResponse();
    //some server return two lines 125 and 226 for transfer finished
    bool isTransferCompleted = response.isSuccessCode();
    if (!isTransferCompleted && response.code != 125 && response.code != 150) {
      throw FTPConnectException('Connection refused. ', response.message);
    }

    // Changed to listen mode instead so that it's possible to send information back on downloaded amount
    _socket.logger.log('Start downloading...');
    var sink = fLocalFile.openWrite(mode: FileMode.writeOnly);
    var received = 0;
    await dataSocket.listen((data) {
      sink.add(data);
      if (onProgress != null) {
        received += data.length;
        var percent = ((received / fileSize) * 100).toStringAsFixed(2);
        //in case that the file size is 0, then pass directly 100
        double percentVal = double.tryParse(percent) ?? 100;
        if (percentVal.isInfinite || percentVal.isNaN) percentVal = 100;
        onProgress(percentVal, received, fileSize);
      }
    }).asFuture();

    await dataSocket.close();
    await sink.flush();
    await sink.close();

    if (!isTransferCompleted) {
      //Test if All data are well transferred
      response = await _socket.readResponse();
      if (!response.isSuccessCode()) {
        throw FTPConnectException('Transfer Error.', response.message);
      }
    }

    _socket.logger.log('File Downloaded!');
    return true;
  }

  /// Upload File [fFile] to the current directory with [remoteName] (using filename if not set)
  Future<bool> upload(
    File fFile, {
    String remoteName = '',
    FileProgress? onProgress,
  }) async {
    _socket.logger.log('Upload File: ${fFile.path}');

    // Enter passive mode
    FTPReply response = await _socket.openDataTransferChannel();

    // Store File
    String sFilename = remoteName;
    if (sFilename.isEmpty) {
      sFilename = basename(fFile.path);
    }

    // The response is the file to upload, witch will be managed by another socket
    _socket.sendCommandWithoutWaitingResponse('STOR $sFilename');

    // Data Transfer Socket
    int iPort = Utils.parsePort(response.message, _socket.supportIPV6);
    _socket.logger.log('Opening DataSocket to Port $iPort');
    final Socket dataSocket = await Socket.connect(_socket.host, iPort);
    //Test if second socket connection accepted or not
    response = await _socket.readResponse();
    //some server return two lines 125 and 226 for transfer finished
    bool isTransferCompleted = response.isSuccessCode();
    if (!isTransferCompleted && response.code != 125 && response.code != 150) {
      throw FTPConnectException('Connection refused. ', response.message);
    }

    _socket.logger.log('Start uploading...');

    var received = 0;
    int fileSize = await fFile.length();

    Stream<List<int>> readStream = fFile.openRead().transform(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          sink.add(data);
          if (onProgress != null) {
            received += data.length;
            var percent = ((received / fileSize) * 100).toStringAsFixed(2);
            //in case that the file size is 0, then pass directly 100
            double percentVal = double.tryParse(percent) ?? 100;
            if (percentVal.isInfinite || percentVal.isNaN) percentVal = 100;
            onProgress(percentVal, received, fileSize);
          }
        },
      ),
    );

    await dataSocket.addStream(readStream);
    await dataSocket.flush();
    await dataSocket.close();

    if (!isTransferCompleted) {
      // Test if All data are well transferred
      response = await _socket.readResponse();
      if (!response.isSuccessCode()) {
        throw FTPConnectException('Transfer Error.', response.message);
      }
    }

    _socket.logger.log('File Uploaded!');
    return true;
  }
}
