import 'package:flutter/material.dart';
import 'dart:io';
import '../services/supabase_service.dart';
import '../services/xopp_parser.dart';
import '../services/storage_service.dart';
import '../services/tags_service.dart';
import 'viewer_screen.dart';
import 'about_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _files = [];
  Map<String, String> _fileTags = {};
  bool _isSyncing = false;
  String _currentPath = ''; // Empty string means Root
  bool _isNavigatingForward = true;

  @override
  void initState() {
    super.initState();
    _loadTags();
    _loadLocalFiles().then((_) => _syncWithCloud());
  }

  Future<void> _loadLocalFiles() async {
    try {
      final dirPath = await StorageService.getStorageDirectory();
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      
      final localEntities = dir.listSync(recursive: true);
      final List<Map<String, dynamic>> localFilesList = [];
      
      for (final entity in localEntities) {
        if (entity is File && entity.path.endsWith('.xopp')) {
          String filename = entity.path.substring(dir.path.length + 1).replaceAll('\\', '/');
          if (filename.startsWith('.') || filename.contains('/.') || filename.contains('.autosave')) {
            continue;
          }
          final lastMod = await entity.lastModified();
          localFilesList.add({
            'filename': filename,
            'last_updated': lastMod.toIso8601String(),
          });
        }
      }
      if (mounted) {
        setState(() {
          _files = localFilesList;
        });
      }
    } catch (e) {
      // Ignore local read errors
    }
  }

  Future<void> _loadTags() async {
    final tags = await TagsService.getTags();
    if (mounted) setState(() => _fileTags = tags);
  }

  Future<void> _syncWithCloud() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    
    int downloadedCount = 0;
    int uploadedCount = 0;

    try {
      final metadata = await SupabaseService.fetchMetadata();
      final dirPath = await StorageService.getStorageDirectory();
      
      // Create a map for quick cloud file lookup
      final cloudFiles = {
        for (var meta in metadata) meta['filename'] as String: meta
      };

      final dir = Directory(dirPath);
      final List<FileSystemEntity> localEntities = dir.existsSync() ? dir.listSync(recursive: true) : [];
      final localFiles = <String, File>{};

      // 1. TWO-WAY SYNC (Upload Phase): Check for new or modified local files to upload
      for (final entity in localEntities) {
        if (entity is File && entity.path.endsWith('.xopp')) {
          // Extract the relative path from the root directory (e.g., 'Math/Calculus/Test.xopp')
          String filename = entity.path.substring(dir.path.length + 1).replaceAll('\\', '/');
          
          // Ignore hidden files and Xournal++ autosave temporaries anywhere in the path
          if (filename.startsWith('.') || filename.contains('/.') || filename.contains('.autosave')) {
            continue;
          }

          localFiles[filename] = entity;
          
          final localDate = await entity.lastModified();
          bool needsUpload = false;
          
          if (!cloudFiles.containsKey(filename)) {
            // Completely new local file found on the SD card
            needsUpload = true;
          } else {
            // File exists in cloud, compare timestamps
            final cloudUpdatedStr = cloudFiles[filename]!['last_updated'] as String?;
            if (cloudUpdatedStr != null) {
              final cloudDate = DateTime.tryParse(cloudUpdatedStr);
              // Use a 2-second tolerance to account for Android/FAT32 filesystem timestamp truncation
              if (cloudDate != null && localDate.difference(cloudDate).inSeconds > 2) {
                needsUpload = true;
              }
            }
          }
          
          if (needsUpload) {
            await SupabaseService.uploadFile(entity, filename);
            uploadedCount++;
          }
        }
      }
      
      // 2. TWO-WAY SYNC (Download Phase): Check for new or modified cloud files to download
      for (final fileMeta in metadata) {
        final filename = fileMeta['filename'] as String;
        
        // Ignore hidden and autosave files that might have snuck into the DB earlier
        if (filename.startsWith('.') || filename.contains('.autosave')) {
          continue;
        }

        final cloudUpdatedStr = fileMeta['last_updated'] as String?;
        final localFile = File('$dirPath/$filename');
        
        bool needsDownload = false;
        DateTime? parsedCloudDate;
        
        if (!await localFile.exists()) {
          needsDownload = true;
          parsedCloudDate = cloudUpdatedStr != null ? DateTime.tryParse(cloudUpdatedStr) : null;
          await TagsService.markAsNew(filename);
        } else if (cloudUpdatedStr != null) {
          parsedCloudDate = DateTime.tryParse(cloudUpdatedStr);
          if (parsedCloudDate != null) {
            final localDate = await localFile.lastModified();
            // Use a 2-second tolerance to account for Android/FAT32 filesystem timestamp truncation
            if (parsedCloudDate.difference(localDate).inSeconds > 2) {
              needsDownload = true;
              await TagsService.markAsUpdated(filename);
            }
          }
        }
        
        if (needsDownload) {
          await SupabaseService.downloadXoppFile(filename, parsedCloudDate);
          downloadedCount++;
        }
      }
      
      await _loadTags();

      // Refresh metadata for the UI because we may have uploaded new files during step 1
      final finalMetadata = await SupabaseService.fetchMetadata();
      
      setState(() {
        _files = finalMetadata.where((m) {
          final fname = m['filename'] as String;
          return !fname.startsWith('.') && !fname.contains('.autosave');
        }).toList();
      });

      if (mounted) {
        String msg = 'Sync Complete!';
        if (downloadedCount > 0 || uploadedCount > 0) {
          msg = 'Synced: $downloadedCount Downloaded ⬇️, $uploadedCount Uploaded ⬆️';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync Failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _openFile(String filename) async {
    await TagsService.clearTag(filename);
    _loadTags();

    final dirPath = await StorageService.getStorageDirectory();
    final localPath = '$dirPath/$filename';
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Parse heavily using Isolate
      final document = await XoppParser.parseFile(localPath);
      final fileObj = File(localPath);
      final lastMod = await fileObj.lastModified();
      Navigator.pop(context); // Close loading dialog
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ViewerScreen(
            document: document,
            originalFileName: filename,
            documentLastModified: lastMod,
          ),
        ),
      );
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open file: $e'), backgroundColor: Colors.red),
      );
    }
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null) return 'Unknown';
    final date = DateTime.tryParse(isoDate)?.toLocal();
    if (date == null) return isoDate;
    
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months[date.month - 1];
    
    int hour = date.hour;
    final ampm = hour >= 12 ? 'PM' : 'AM';
    if (hour > 12) hour -= 12;
    if (hour == 0) hour = 12;
    
    final minute = date.minute.toString().padLeft(2, '0');
    
    return '$month ${date.day}, $hour:$minute $ampm';
  }

  void _showAboutFile(Map<String, dynamic> file) async {
    final dirPath = await StorageService.getStorageDirectory();
    final localFile = File('$dirPath/${file['filename']}');
    String fileSizeStr = 'Unknown';
    if (await localFile.exists()) {
      final bytes = await localFile.length();
      fileSizeStr = '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2D2D2D),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('File Details', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              _buildDetailRow('Filename', (file['filename'] as String).split('/').last),
              const SizedBox(height: 12),
              _buildDetailRow('Cloud Updated', _formatDate(file['last_updated'])),
              const SizedBox(height: 12),
              _buildDetailRow('Local Cache Size', fileSizeStr),
              const SizedBox(height: 12),
              _buildDetailRow('Storage Path', dirPath),
              const SizedBox(height: 30),
            ],
          ),
        );
      }
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 140, child: Text(label, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold))),
        Expanded(child: Text(value, style: const TextStyle(color: Colors.white))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1. Parse current directory contents
    final List<Map<String, dynamic>> displayedItems = [];
    final Set<String> foldersInCurrentPath = {};
    final List<Map<String, dynamic>> filesInCurrentPath = [];

    for (final file in _files) {
      final String filename = file['filename']; // e.g. "Math/Calculus/Test.xopp"
      if (_currentPath.isEmpty || filename.startsWith('$_currentPath/')) {
        final relativeToCurrent = _currentPath.isEmpty ? filename : filename.substring(_currentPath.length + 1);
        
        final parts = relativeToCurrent.split('/');
        if (parts.length > 1) {
          // It's a folder
          foldersInCurrentPath.add(parts.first);
        } else {
          // It's a file
          filesInCurrentPath.add(file);
        }
      }
    }

    // Add folders to display
    for (final folder in foldersInCurrentPath.toList()..sort()) {
      displayedItems.add({
        'is_folder': true,
        'name': folder,
        'full_path': _currentPath.isEmpty ? folder : '$_currentPath/$folder',
      });
    }

    // Add files to display
    for (final file in filesInCurrentPath) {
      final name = (file['filename'] as String).split('/').last;
      displayedItems.add({
        'is_folder': false,
        'name': name,
        'file_data': file,
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E), // Cobble Dark Theme
      appBar: AppBar(
        title: _currentPath.isEmpty
            ? const Text('Cobble Workspace')
            : Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      setState(() {
                        _isNavigatingForward = false;
                        final parts = _currentPath.split('/');
                        parts.removeLast();
                        _currentPath = parts.join('/');
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentPath.split('/').last,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
        backgroundColor: const Color(0xFF2D2D2D),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Storage Settings',
            onPressed: () async {
              final currentPath = await StorageService.getStorageDirectory();
              if (!mounted) return;
              
              showDialog(
                context: context,
                builder: (BuildContext dialogContext) {
                  return AlertDialog(
                    backgroundColor: const Color(0xFF2D2D2D),
                    title: const Text('Storage Location', style: TextStyle(color: Colors.white)),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Current Sync Folder:', style: TextStyle(color: Colors.white54, fontSize: 12)),
                        const SizedBox(height: 8),
                        Text(currentPath, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          final success = await StorageService.pickCustomStorageDirectory();
                          if (success && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Storage path updated. Syncing...'), backgroundColor: Colors.blueAccent),
                            );
                            _syncWithCloud();
                          }
                        },
                        child: const Text('Change Folder', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About Application',
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()));
            },
          ),
        ],
      ),
      body: _isSyncing && _files.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.blueAccent),
                  SizedBox(height: 20),
                  Text('Syncing with Cloud...', style: TextStyle(color: Colors.white)),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: const Color(0xFF252525),
                  width: double.infinity,
                  child: Row(
                    children: [
                      const Icon(Icons.account_tree, color: Colors.blueAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _currentPath.isEmpty ? 'Workspace Root' : 'Workspace Root > ${_currentPath.replaceAll('/', ' > ')}',
                          style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _syncWithCloud,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (Widget child, Animation<double> animation) {
                        final inAnimation = Tween<Offset>(
                          begin: Offset(_isNavigatingForward ? 1.0 : -1.0, 0.0),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
                        
                        final outAnimation = Tween<Offset>(
                          begin: Offset(_isNavigatingForward ? -1.0 : 1.0, 0.0),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));

                        final offsetAnimation = (child.key == ValueKey(_currentPath)) 
                            ? inAnimation 
                            : outAnimation;

                        return SlideTransition(
                          position: offsetAnimation,
                          child: Container(
                            color: const Color(0xFF1E1E1E), // Solid background prevents text overlap
                            child: child,
                          ),
                        );
                      },
                      child: ListView.builder(
                        key: ValueKey(_currentPath),
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: displayedItems.length,
                        itemBuilder: (context, index) {
                          final item = displayedItems[index];

                          if (item['is_folder'] == true) {
                            // RENDER FOLDER
                            final folderName = item['name'] as String;
                            return ListTile(
                              leading: const Icon(Icons.folder, color: Colors.blueAccent, size: 36),
                              title: Text(
                                folderName,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              onTap: () {
                                setState(() {
                                  _isNavigatingForward = true;
                                  _currentPath = item['full_path'] as String;
                                });
                              },
                            );
                          }

                          // RENDER FILE
                          final file = item['file_data'] as Map<String, dynamic>;
                          final fullFilename = file['filename'] as String;
                          final displayName = item['name'] as String;
                          final tag = _fileTags[fullFilename];

                          return Dismissible(
                            key: Key(fullFilename),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: Colors.redAccent,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            onDismissed: (direction) async {
                              // Optimistically remove from UI
                              setState(() => _files.remove(file));
                              
                              final snackBar = SnackBar(
                                content: Text('Deleted $displayName'),
                                duration: const Duration(seconds: 4),
                                action: SnackBarAction(
                                  label: 'UNDO',
                                  textColor: Colors.yellow,
                                  onPressed: () {
                                    // Restore the file to the UI
                                    if (mounted) setState(() => _files.add(file));
                                  },
                                ),
                              );

                              ScaffoldMessenger.of(context).showSnackBar(snackBar).closed.then((reason) async {
                                if (reason != SnackBarClosedReason.action) {
                                  // User did not press UNDO, execute permanent deletion
                                  try {
                                    await SupabaseService.deleteFile(fullFilename);
                                  } catch (e) {
                                    if (mounted) {
                                      setState(() => _files.add(file));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
                                      );
                                    }
                                  }
                                }
                              });
                            },
                            child: ListTile(
                              leading: const Icon(Icons.insert_drive_file, color: Colors.blueAccent),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      displayName,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (tag != null)
                                    Container(
                                      margin: const EdgeInsets.only(left: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: tag == 'new' ? Colors.green : Colors.blue,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        tag.toUpperCase(),
                                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                      ),
                                    )
                                ],
                              ),
                              subtitle: Text(
                                'Updated: ${_formatDate(file['last_updated'])}',
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              onTap: () => _openFile(fullFilename),
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, color: Colors.white54),
                                color: const Color(0xFF2D2D2D),
                                onSelected: (value) async {
                                  if (value == 'about') {
                                    _showAboutFile(file);
                                  } else if (value == 'delete') {
                                    setState(() => _files.remove(file));
                                    
                                    final snackBar = SnackBar(
                                      content: Text('Deleted $displayName'),
                                      duration: const Duration(seconds: 4),
                                      action: SnackBarAction(
                                        label: 'UNDO',
                                        textColor: Colors.yellow,
                                        onPressed: () {
                                          if (mounted) setState(() => _files.add(file));
                                        },
                                      ),
                                    );

                                    ScaffoldMessenger.of(context).showSnackBar(snackBar).closed.then((reason) async {
                                      if (reason != SnackBarClosedReason.action) {
                                        try {
                                          await SupabaseService.deleteFile(fullFilename);
                                        } catch (e) {
                                          if (mounted) {
                                            setState(() => _files.add(file));
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
                                            );
                                          }
                                        }
                                      }
                                    });
                                  }
                                },
                                itemBuilder: (BuildContext context) => [
                                  const PopupMenuItem(
                                    value: 'about',
                                    child: Text('About File', style: TextStyle(color: Colors.white)),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
              ),
    );
  }
}
