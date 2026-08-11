import 'package:flutter/services.dart';

/// Thin Dart side of the Storage Access Framework bridge in `MainActivity.kt`.
///
/// Both calls resolve to `null` when the user dismisses the system dialog,
/// which callers should treat as "nothing to do" rather than an error.
abstract final class FileChannel {
  static const _channel = MethodChannel('com.memapp.app/files');

  /// Opens the system file picker and returns the chosen file's contents.
  static Future<String?> pickJson() async {
    try {
      return await _channel.invokeMethod<String>('pickJson');
    } on PlatformException catch (e) {
      throw FileChannelException(e.message ?? 'Could not read that file');
    } on MissingPluginException {
      throw const FileChannelException(
          'File access is unavailable on this platform');
    }
  }

  /// Opens the system "Save as" dialog. Returns the destination URI, or null
  /// if the user cancelled.
  static Future<String?> saveJson({
    required String fileName,
    required String content,
  }) async {
    try {
      return await _channel.invokeMethod<String>('saveJson', {
        'fileName': fileName,
        'content': content,
      });
    } on PlatformException catch (e) {
      throw FileChannelException(e.message ?? 'Could not save that file');
    } on MissingPluginException {
      throw const FileChannelException(
          'File access is unavailable on this platform');
    }
  }
}

class FileChannelException implements Exception {
  const FileChannelException(this.message);
  final String message;
  @override
  String toString() => message;
}
