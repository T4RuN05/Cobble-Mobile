import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static const String _storageKey = 'cobble_custom_storage_path';
  static String? _cachedPath;

  /// Retrieves the current storage path. If no custom path is set, 
  /// it defaults to the application documents directory.
  static Future<String> getStorageDirectory() async {
    if (_cachedPath != null) return _cachedPath!;
    
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString(_storageKey);
    
    if (customPath != null && customPath.isNotEmpty) {
      final dir = Directory(customPath);
      if (await dir.exists()) {
        _cachedPath = customPath;
        return customPath;
      }
    }
    
    // Fallback to internal sandbox
    final dir = await getApplicationDocumentsDirectory();
    _cachedPath = dir.path;
    return dir.path;
  }

  /// Checks if a custom path has been set by the user.
  static Future<bool> hasCustomPathSet() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_storageKey);
  }

  /// Requests the necessary Android permissions and opens a folder picker.
  /// Returns true if a folder was successfully selected and saved.
  static Future<bool> pickCustomStorageDirectory() async {
    // On Android 11+, we need MANAGE_EXTERNAL_STORAGE to write anywhere.
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        final result = await Permission.manageExternalStorage.request();
        if (!result.isGranted) {
          // Fallback to standard storage permission for older Androids
          final legacyStatus = await Permission.storage.request();
          if (!legacyStatus.isGranted) {
            return false;
          }
        }
      }
    }

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, selectedDirectory);
      _cachedPath = selectedDirectory;
      return true;
    }
    return false;
  }
}
