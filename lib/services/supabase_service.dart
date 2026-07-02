import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'storage_service.dart';

class SupabaseService {
  static const String _url = 'https://rcztclkkcpxsosptdgwe.supabase.co';
  static const String _anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJjenRjbGtrY3B4c29zcHRkZ3dlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI5MjUxMzYsImV4cCI6MjA5ODUwMTEzNn0.HFdE91Yrc6__cnT3sR2mePPJTYPj6wVSfObUNXJ_gQM';

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: _url,
      anonKey: _anonKey,
    );
  }

  static SupabaseClient get client => Supabase.instance.client;

  /// Fetches the latest metadata from Supabase
  static Future<List<Map<String, dynamic>>> fetchMetadata() async {
    final response = await client
        .from('cobble_metadata')
        .select('*')
        .order('last_updated', ascending: false);
    
    return List<Map<String, dynamic>>.from(response);
  }

  /// Downloads a file from the cobble_docs storage bucket
  static Future<File> downloadXoppFile(String filename, [DateTime? cloudDate]) async {
    final bytes = await client.storage.from('cobble_docs').download(filename);
    
    final dirPath = await StorageService.getStorageDirectory();
    final file = File('$dirPath/$filename');
    
    // Ensure the nested subdirectories exist before trying to save the file
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    
    await file.writeAsBytes(bytes);
    
    if (cloudDate != null) {
      await file.setLastModified(cloudDate);
    }
    
    return file;
  }

  /// Uploads a local file to the cobble_docs storage bucket and upserts metadata
  static Future<void> uploadFile(File file, String filename) async {
    // 1. Upload to storage bucket (upsert to overwrite if exists)
    final bytes = await file.readAsBytes();
    await client.storage.from('cobble_docs').uploadBinary(
      filename, 
      bytes, 
      fileOptions: const FileOptions(upsert: true),
    );
    
    // 2. Upsert into metadata table using the actual file's modification time
    final lastMod = await file.lastModified();
    await client.from('cobble_metadata').upsert({
      'filename': filename,
      'last_updated': lastMod.toUtc().toIso8601String(),
    }, onConflict: 'filename');
  }

  /// Deletes a file from both the metadata table and the storage bucket
  static Future<void> deleteFile(String filename) async {
    // Delete from metadata table
    await client.from('cobble_metadata').delete().eq('filename', filename);
    
    // Delete from storage
    await client.storage.from('cobble_docs').remove([filename]);
    
    // Delete local cached file if it exists
    final dirPath = await StorageService.getStorageDirectory();
    final file = File('$dirPath/$filename');
    if (await file.exists()) {
      await file.delete();
    }
  }
}
