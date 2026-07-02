import 'package:supabase/supabase.dart';

void main() async {
  final client = SupabaseClient('https://rcztclkkcpxsosptdgwe.supabase.co', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJjenRjbGtrY3B4c29zcHRkZ3dlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI5MjUxMzYsImV4cCI6MjA5ODUwMTEzNn0.HFdE91Yrc6__cnT3sR2mePPJTYPj6wVSfObUNXJ_gQM');
  
  print('Fetching metadata...');
  final metadata = await client.from('cobble_metadata').select('filename');
  
  if (metadata.isNotEmpty) {
    print('Deleting ${metadata.length} files...');
    for (var m in metadata) {
      final filename = m['filename'] as String;
      print('Deleting $filename');
      await client.from('cobble_metadata').delete().eq('filename', filename);
      await client.storage.from('cobble_docs').remove([filename]);
    }
    print('Database and bucket cleared successfully!');
  } else {
    print('Database is already empty.');
  }
}
