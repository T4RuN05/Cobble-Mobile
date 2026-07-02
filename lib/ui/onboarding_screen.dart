import 'package:flutter/material.dart';
import 'home_screen.dart';
import '../services/storage_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  _OnboardingScreenState createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _isLoading = false;

  Future<void> _pickStorage() async {
    setState(() => _isLoading = true);
    
    final success = await StorageService.pickCustomStorageDirectory();
    
    setState(() => _isLoading = false);
    
    if (success && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Permission denied or no folder selected. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.folder_special, size: 100, color: Colors.blueAccent),
              const SizedBox(height: 32),
              const Text(
                'Welcome to Cobble',
                style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Cobble securely syncs your files from the cloud. To avoid filling up your internal storage, please grant "All Files Access" and choose a specific folder on your SD Card or Device Storage.',
                style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              if (_isLoading)
                const Center(child: CircularProgressIndicator(color: Colors.blueAccent))
              else
                ElevatedButton.icon(
                  icon: const Icon(Icons.create_new_folder, color: Colors.white),
                  label: const Text('Choose Storage Folder', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _pickStorage,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
