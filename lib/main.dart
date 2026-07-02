import 'package:flutter/material.dart';
import 'services/supabase_service.dart';
import 'services/storage_service.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Supabase Connection
  await SupabaseService.initialize();
  
  runApp(const CobbleMobileApp());
}

class CobbleMobileApp extends StatelessWidget {
  const CobbleMobileApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cobble Mobile',
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF2D2D2D),
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      ),
      home: const SplashScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
