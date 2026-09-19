// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // [เพิ่ม] Import Firestore

import 'firebase_options.dart';
import 'login_page.dart';
import 'projects_page.dart';

// import background service เฉพาะ mobile
import 'background_service.dart'
    if (dart.library.html) 'background_service_stub.dart';

// main.dart (ส่วนของฟังก์ชัน main)

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // --- [แก้ไข] การตั้งค่า Offline Persistence สำหรับเวอร์ชันใหม่ ---
  try {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true, // เปิดใช้งาน Offline Cache ทั้งบน Web และ Mobile
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED, // ไม่จำกัดขนาดของแคช
    );
    debugPrint("ตั้งค่า Offline Persistence สำเร็จ");
  } catch (e) {
    debugPrint("เกิดข้อผิดพลาดในการตั้งค่า Offline Mode: $e");
  }
  // ---------------------------------------------------------

  if (!kIsWeb) {
    await initializeService();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ระบบตรวจคุณภาพวัดดิน',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('th', 'TH'),
      ],
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) {
          return const ProjectsPage();
        }
        return const LoginPage();
      },
    );
  }
}