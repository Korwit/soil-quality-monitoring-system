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

  service.on('updateNPK').listen((event) async {
    if (event == null) return;

    final int n = event['n'] ?? 0;
    final int p = event['p'] ?? 0;
    final int k = event['k'] ?? 0;
    final int moisture = event['moisture'] ?? 0;
    final double ph = event['ph'] ?? 0.0;
  
    try {
      final prefs = await SharedPreferences.getInstance();
      final gardenId = prefs.getString('bg_garden_id');
      final inspectId = prefs.getString('bg_inspect_id');
      
      final userUid = prefs.getString('bg_user_uid');
      final userEmail = prefs.getString('bg_user_email');

      if (gardenId == null || inspectId == null) {
        debugPrint('[BG] Error: ไม่พบ Garden ID หรือ Inspect ID');
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      FirebaseFirestore.instance
          .collection('gardens')
          .doc(gardenId)
          .collection('inspections')
          .doc(inspectId)
          .collection('points')
          .add({
        'latitude':  position.latitude,
        'longitude': position.longitude,
        'altitude':  position.altitude,
        'timestamp': Timestamp.fromDate(DateTime.now()),
        'n_value':   n,
        'p_value':   p,
        'k_value':   k,
        'moisture':  moisture,
        'ph_value':  ph,
        'source':    'Auto (BLE)',
        'created_by_uid': userUid,
        'created_by_email': userEmail,
      });

      debugPrint('[BG] บันทึกสำเร็จ @ (${position.latitude}, ${position.longitude}) โดย: $userEmail');

      service.invoke('sendAckToBLE', {});
      debugPrint('[BG] invoke sendAckToBLE → UI isolate แล้ว');

      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          service.setForegroundNotificationInfo(
            title: 'บันทึกสำเร็จ ✓',
            content:
                'N:$n P:$p K:$k pH:$ph | ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')} น.',
          );
        }
      }

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