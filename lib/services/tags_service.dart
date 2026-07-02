import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class TagsService {
  static const String _filename = 'tags.json';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_filename');
  }

  /// Returns a map of filenames to their status tag ('new' or 'updated')
  static Future<Map<String, String>> getTags() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return {};
      final contents = await file.readAsString();
      final Map<String, dynamic> decoded = jsonDecode(contents);
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      return {};
    }
  }

  static Future<void> _saveTags(Map<String, String> tags) async {
    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode(tags));
    } catch (e) {
      // Ignore write errors
    }
  }

  static Future<void> markAsNew(String filename) async {
    final tags = await getTags();
    tags[filename] = 'new';
    await _saveTags(tags);
  }

  static Future<void> markAsUpdated(String filename) async {
    final tags = await getTags();
    tags[filename] = 'updated';
    await _saveTags(tags);
  }

  static Future<void> clearTag(String filename) async {
    final tags = await getTags();
    if (tags.containsKey(filename)) {
      tags.remove(filename);
      await _saveTags(tags);
    }
  }
}
