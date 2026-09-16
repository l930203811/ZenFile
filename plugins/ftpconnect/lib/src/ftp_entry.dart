import 'package:intl/intl.dart';

import 'ftp_exceptions.dart';
import 'ftpconnect_base.dart';

class FTPEntry {
  final String name;
  final DateTime? modifyTime;
  final String? permission;
  final FTPEntryType type;
  final int? size;
  final String? unique;
  final String? group;
  final int? gid;
  final String? mode;
  final String? owner;
  final int? uid;
  final Map<String, String>? additionalProperties;

  static final RegExp regexpLIST = RegExp(r"^([\-ld])" // Directory flag [1]
      r"([\-rwxs]{9})\s+" // Permissions [2]
      r"(\d+)\s+" // Number of items [3]
      r"(\w+)\s+" // File owner [4]
      r"(\w+)\s+" // File group [5]
      r"(\d+)\s+" // File size in bytes [6]
      r"(\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{1,2}|\d{4}))\s+" // date[7]
      r"(.+)$" //file/dir name[8]
      );

  static final regexpLISTSiiServers = RegExp(r"^(.{8}\s+.{7})\s+" //date[1]
      r"(.{0,5})\s+" //type file or dir [2]
      r"(\d{0,24})\s+" //size [3]
      r"(.+)$" //file/ dir name [4]
      );

  // Hide constructor
  FTPEntry._(
      this.name,
      this.modifyTime,
      this.permission,
      this.type,
      this.size,
      this.unique,
      this.group,
      this.gid,
      this.mode,
      this.owner,
      this.uid,
      this.additionalProperties);

  factory FTPEntry.parse(String responseLine, ListCommand cmd) {
    if (responseLine.trim().isEmpty) {
      throw FTPConnectException("Can't parse a null or blank response line");
    }
    if (cmd == ListCommand.list) {
      return FTPEntry._parseListCommand(responseLine);
    } else if (cmd == ListCommand.nlst) {
      return FTPEntry._(responseLine, null, null, FTPEntryType.unknown, null,
          null, null, null, null, null, null, null);
    } else {
      return FTPEntry._parseMLSDCommand(responseLine);
    }
  }

  factory FTPEntry._parseMLSDCommand(final String responseLine) {
    String name = "";
    DateTime? modifyTime;
    String? permission;
    FTPEntryType type = FTPEntryType.unknown;
    int size = 0;
    String? unique;
    String? group;
    int gid = -1;
    String? mode;
    String? owner;
    int uid = -1;
    Map<String, String> additional = {};

    // Split and trim line
    responseLine.trim().split(';').forEach((property) {
      final prop = property
          .split('=')
          .map((part) => part.trim())
          .toList(growable: false);

      if (prop.length == 1) {
        // Name
        name = prop[0];
      } else {
        // Other attributes
        switch (prop[0].toLowerCase()) {
          case 'modify':
            final String date =
                '${prop[1].substring(0, 8)}T${prop[1].substring(8)}';
            modifyTime = DateTime.tryParse(prop[1]) ?? DateTime.tryParse(date);
            break;
          case 'perm':
            permission = prop[1];
            break;
          case 'size':
            size = int.parse(prop[1]);
            break;
          case 'type':
            if (prop[1] == 'dir') {
              type = FTPEntryType.dir;
            } else if (prop[1] == 'file') {
              type = FTPEntryType.file;
            } else {
              type = FTPEntryType.link;
            }
            break;
          case 'unique':
            unique = prop[1];
            break;
          case 'unix.group':
            group = prop[1];
            break;
          case 'unix.gid':
            gid = int.parse(prop[1]);
            break;
          case 'unix.mode':
            mode = prop[1];
            break;
          case 'unix.owner':
            owner = prop[1];
            break;
          case 'unix.uid':
            uid = int.parse(prop[1]);
            break;
          default:
            additional.putIfAbsent(prop[0], () => prop[1]);
            break;
        }
      }
    });

    return FTPEntry._(name, modifyTime, permission, type, size, unique, group,
        gid, mode, owner, uid, Map.unmodifiable(additional));
  }

  ///reference http://cr.yp.to/ftp/list/binls.html
  ///-rw-r--r-- 1 owner group           213 Aug 26 16:31 FileName.txt
  ///d for Dir
  ///- for file
  ///
  /// SII servers format:
  /// 02-11-15  03:05PM      \<DIR>     1410887680 directory
  /// 02-11-15  03:05PM               1410887680 file.avi
  factory FTPEntry._parseListCommand(final String responseLine) {
    if (regexpLIST.hasMatch(responseLine)) {
      return FTPEntry._parseLIST(responseLine);
    } else if (regexpLISTSiiServers.hasMatch(responseLine)) {
      return FTPEntry._parseLISTiis(responseLine);
    } else {
      throw FTPConnectException(
          'Invalid format <$responseLine> for LIST command response !');
    }
  }

  factory FTPEntry._parseLIST(final String responseLine) {
    String name = "";
    DateTime? modifyTime;
    String? persmission;
    FTPEntryType type = FTPEntryType.unknown;
    int size = 0;
    String? unique;
    String? group;
    int gid = -1;
    String? mode;
    String? owner;
    int uid = -1;

    Iterable<Match> matches = regexpLIST.allMatches(responseLine);
    for (Match match in matches) {
      if (match.group(1) == "-") {
        type = FTPEntryType.file;
      } else if (match.group(1) == "d") {
        type = FTPEntryType.dir;
      } else {
        type = FTPEntryType.link;
      }

      //permission
      persmission = match.group(2);
      //nb files
      //var nbFiles = match.group(3);
      //owner
      owner = match.group(4);
      //group
      group = match.group(5);
      //size
      size = int.tryParse(match.group(6)!) ?? 0;
      //date
      String date = (match.group(7)!.split(" ")..removeWhere((i) => i.isEmpty))
          .join(" "); //keep only one space
      //insert year
      if (date.contains(':')) date = '$date ${DateTime.now().year}';
      var format = date.contains(':') ? 'MMM dd hh:mm yyyy' : 'MMM dd yyyy';
      modifyTime = DateFormat(format, 'en_US').parse(date);
      //file/dir name
      name = match.group(8)!;
    }
    return FTPEntry._(name, modifyTime, persmission, type, size, unique, group,
        gid, mode, owner, uid, {});
  }

  factory FTPEntry._parseLISTiis(final String responseLine) {
    String name = "";
    DateTime? modifyTime;
    String? persmission;
    FTPEntryType type = FTPEntryType.unknown;
    int size = 0;
    String? unique;
    String? group;
    int gid = -1;
    String? mode;
    String? owner;
    int uid = -1;
    Iterable<Match> matches = regexpLISTSiiServers.allMatches(responseLine);
    for (Match match in matches) {
      //date
      String date =
          match.group(1)!.split(" ").fold('', (previousValue, element) {
        //keep only one space and add fullyear if only last 2 digits in year
        if (element.isEmpty) return previousValue;
        if (previousValue.isEmpty) {
          return element.length <= 8
              ? element.substring(0, 6) +
                  DateTime.now().year.toString().substring(0, 2) +
                  element.substring(6, 8)
              : element;
        }
        return '$previousValue $element';
      });
      modifyTime = DateFormat('MM-dd-yyyy hh:mma').parse(date);

      //type
      if (match.group(2)!.trim().isEmpty) {
        type = FTPEntryType.file;
      } else if (match.group(2)!.toLowerCase().contains("dir")) {
        type = FTPEntryType.dir;
      } else {
        type = FTPEntryType.link;
      }
      //size
      size = int.tryParse(match.group(3)!) ?? 0;

      //file/dir name
      name = match.group(4)!;
    }
    return FTPEntry._(name, modifyTime, persmission, type, size, unique, group,
        gid, mode, owner, uid, {});
  }

  @override
  String toString() =>
      'name=$name;modify=$modifyTime;perm=$permission;type=${type.describeEnum.toLowerCase()};size=$size;unique=$unique;unix.group=$group;unix.mode=$mode;unix.owner=$owner;unix.uid=$uid;unix.gid=$gid';
}

enum FTPEntryType { file, dir, link, unknown }

extension FtpEntryTypeEnum on FTPEntryType {
  String get describeEnum => toString().substring(toString().indexOf('.') + 1);
}
