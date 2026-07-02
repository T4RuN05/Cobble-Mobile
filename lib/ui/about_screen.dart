import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({Key? key}) : super(key: key);

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: const Text('About Application'),
        backgroundColor: const Color(0xFF2D2D2D),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24.0),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/app_logo.png',
                width: 80,
                height: 80,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Cobble',
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Version 1.0.0 (Production)',
                style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'About',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Cobble is a premium companion application for Xournal++ users who want to carry their handwritten notes, journals, and annotations anywhere they go. It bridges the gap between your desktop workspace and your mobile device, providing a native, highly-optimized viewing experience for .xopp files right in your pocket. Whether you are reviewing math notes, quickly referencing an annotated PDF, or sharing your exported pages with others, Cobble ensures that your vector-drawn ink is rendered exactly as you created it. It takes the heavy lifting out of file management by syncing directly to your cloud, giving you instantaneous, offline-ready access to your entire digital notebook collection.',
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 32),
          const Text(
            'Developer',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(
              backgroundColor: Colors.transparent,
              backgroundImage: NetworkImage('https://github.com/T4RuN05.png'),
              radius: 20,
            ),
            title: const Text('Tarun', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            subtitle: const Text('View GitHub Profile (@T4RuN05)', style: TextStyle(color: Colors.blueAccent)),
            onTap: () => _launchUrl('https://github.com/T4RuN05'),
          ),
          const SizedBox(height: 32),
          const Text(
            'Repositories',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.code, color: Colors.white70),
            title: const Text('Cobble Mobile (GitHub)', style: TextStyle(color: Colors.white)),
            subtitle: const Text('https://github.com/T4RuN05/Cobbel', style: TextStyle(color: Colors.blueAccent)),
            onTap: () => _launchUrl('https://github.com/T4RuN05/Cobbel'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.code, color: Colors.white70),
            title: const Text('Xournal++ Desktop (GitHub)', style: TextStyle(color: Colors.white)),
            subtitle: const Text('https://github.com/xournalpp/xournalpp', style: TextStyle(color: Colors.blueAccent)),
            onTap: () => _launchUrl('https://github.com/xournalpp/xournalpp'),
          ),
        ],
      ),
    );
  }
}
