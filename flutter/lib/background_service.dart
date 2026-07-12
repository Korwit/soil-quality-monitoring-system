import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

// ─────────────────────────────────────────────
// 1. Initialize Service
// ─────────────────────────────────────────────
Future<void> initializeService() async {
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'npk_tracking',
    'ระบบบันทึก NPK อัตโนมัติ',
    description: 'Background service สำหรับบันทึกค่าดิน NPK และพิกัด GPS',
    importance: Importance.low,
  );

  await FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'npk_tracking',
      initialNotificationTitle: 'ระบบบันทึกอัตโนมัติทำงานอยู่',
      initialNotificationContent: 'กำลังรอรับค่าจากเซนเซอร์...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// ─────────────────────────────────────────────
// 2. Background Task Execution
// ─────────────────────────────────────────────
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // รอรับ event 'updateNPK' ที่ส่งมาจาก BLEService ในฝั่งแอป
  service.on('updateNPK').listen((event) async {
    if (event == null) return;

    final int n = event['n'] ?? 0;
    final int p = event['p'] ?? 0;
    final int k = event['k'] ?? 0;
    final int moisture = event['moisture'] ?? 0;
    final double ph = event['ph'] ?? 0.0; // ✅ ดึงค่า pH จาก Event (ตั้งค่าเริ่มต้นเป็น 0.0)
  
    try {
      final prefs = await SharedPreferences.getInstance();
      final gardenId = prefs.getString('bg_garden_id');
      final inspectId = prefs.getString('bg_inspect_id');
      
      // ✅ ดึงข้อมูลของคนที่กดเปิดโหมด Auto-save
      final userUid = prefs.getString('bg_user_uid');
      final userEmail = prefs.getString('bg_user_email');

      if (gardenId == null || inspectId == null) {
        debugPrint('[BG] Error: ไม่พบ Garden ID หรือ Inspect ID');
        return;
      }

      // ขอพิกัด GPS ปัจจุบัน ณ วินาทีที่เซนเซอร์ส่งค่ามา
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // บันทึกลง Firestore พร้อมระบุชื่อคนทำ
      await FirebaseFirestore.instance
          .collection('gardens')
          .doc(gardenId)
          .collection('inspections')
          .doc(inspectId)
          .collection('points')
          .add({
        'latitude':  position.latitude,
        'longitude': position.longitude,
        'altitude':  position.altitude,
        'timestamp': FieldValue.serverTimestamp(),
        'n_value':   n,
        'p_value':   p,
        'k_value':   k,
        'moisture':  moisture,
        'ph_value':  ph, // ✅ บันทึกค่า pH ลง Firestore
        'source':    'Auto (BLE)',
        'created_by_uid': userUid,       // ✅ บันทึก UID ของพนักงาน
        'created_by_email': userEmail,   // ✅ บันทึก Email ของพนักงาน
      });

      debugPrint('[BG] บันทึกสำเร็จ @ (${position.latitude}, ${position.longitude}) โดย: $userEmail');

      // ส่ง event กลับ UI isolate เพื่อให้ UI เป็นคน writeAck() ไปบอก ESP32 ว่าบันทึกแล้ว
      service.invoke('sendAckToBLE', {});
      debugPrint('[BG] invoke sendAckToBLE → UI isolate แล้ว');

      // อัปเดตข้อมูลบนแถบ Notification ของโทรศัพท์
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          service.setForegroundNotificationInfo(
            title: 'บันทึกสำเร็จ ✓',
            
            content:
                'N:$n P:$p K:$k pH:$ph | ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')} น.',
          );
        }
      }

      // ส่ง event กลับ UI เพื่อพล็อตจุดใหม่ลงบนแผนที่ทันที
      service.invoke('onDataSaved', {
        'latitude':  position.latitude,
        'longitude': position.longitude,
        'n': n, 'p': p, 'k': k,
        'ph': ph, 
        'timestamp': DateTime.now().toIso8601String(),
      });

    } catch (e) {
      debugPrint('[BG] Error: $e');
    }
  });
}