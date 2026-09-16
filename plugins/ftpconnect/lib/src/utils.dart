import 'dart:async';

class Utils {
  Utils._();

  static int parsePort(String response, bool isIPV6) {
    return isIPV6 ? parsePortEPSV(response) : parsePortPASV(response);
  }

  /// Parse the Passive Mode Port from the Servers [sResponse]
  /// port format (|||xxxxx|)
  static int parsePortEPSV(String sResponse) {
    int iParOpen = sResponse.indexOf('(');
    int iParClose = sResponse.indexOf(')');

    if (iParClose > -1 && iParOpen > -1) {
      sResponse = sResponse.substring(iParOpen + 4, iParClose - 1);
    }
    return int.parse(sResponse);
  }

  /// Parse the Passive Mode Port from the Servers [sResponse]
  /// format 227 Entering Passive Mode (192,168,8,36,8,75).
  static int parsePortPASV(String sResponse) {
    int iParOpen = sResponse.indexOf('(');
    int iParClose = sResponse.indexOf(')');

    String sParameters = sResponse.substring(iParOpen + 1, iParClose);
    List<String> lstParameters = sParameters.split(',');

    int iPort1 = int.parse(lstParameters[lstParameters.length - 2]);
    int iPort2 = int.parse(lstParameters[lstParameters.length - 1]);

    return (iPort1 * 256) + iPort2;
  }

  ///retry a function [retryCount] times, until exceed [retryCount] or execute the function successfully
  ///Return true if the future executed successfully , false other wises
  static Future<bool> retryAction(
      FutureOr<bool> Function() action, retryCount) async {
    int lAttempts = 1;
    bool result = true;
    await Future.doWhile(() async {
      try {
        result = await action();
        //if there is no exception we exit the loop (return false to exit)
        return false;
      } catch (e) {
        if (lAttempts++ >= retryCount) {
          rethrow;
        }
      }
      //return true to loop again
      return true;
    });
    return result;
  }
}
