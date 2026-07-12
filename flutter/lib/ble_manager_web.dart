import 'package:flutter/material.dart';
import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class BLEService {
  static final BLEService _instance = BLEService._internal();
  factory BLEService() => _instance;
  BLEService._internal();

  BluetoothDevice? connectedDevice;
  bool _isManualReading = false;

  // ✅ ตัวแปรระดับ Global อยู่ตลอดการเปิดแอป
  Map<String, int>? _lastSavedData;

  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String charUuid    = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  final String ackUuid     = "beb5483e-36e1-4688-b7f5-ea07361b26a9";

  bool get isConnected => connectedDevice != null;

  // ✅ ฟังก์ชันสำหรับจำค่าเมื่อกดบันทึกลง Firebase สำเร็จ
  void markAsSaved(int n, int p, int k, int m) {
    _lastSavedData = {'n': n, 'p': p, 'k': k, 'moisture': m};
  }

  Future<void> connect(BluetoothDevice device, {VoidCallback? onDisconnected}) async {
    try {
      await device.connect();
      connectedDevice = device;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (connectedDevice != null) {
      connectedDevice!.disconnect();
      connectedDevice = null;
    }
  }

  Future<void> writeAck() async {
    if (!isConnected || connectedDevice == null) return;
    try {
      final services = await connectedDevice!.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid.toLowerCase() == serviceUuid.toLowerCase(),
        orElse: () => throw Exception("ไม่พบ Service: $serviceUuid")
      );
      final char = await service.getCharacteristic(ackUuid.toLowerCase());
      await char.writeValueWithResponse(Uint8List.fromList(utf8.encode("OK")));
      //await char.writeValueWithoutResponse(Uint8List.fromList(utf8.encode("OK")));
    } catch (e) {
      debugPrint('[BLE Web] Write ACK Error: $e');
    }
  }

  Future<Map<String, int>> readNPK() async {
    if (!isConnected || connectedDevice == null) {
      throw Exception("อุปกรณ์ไม่ได้เชื่อมต่อ หรือสัญญาณบลูทูธหลุดไปแล้ว");
    }
    _isManualReading = true;
    try {
      final services = await connectedDevice!.discoverServices();
      
      final service = services.firstWhere(
        (s) => s.uuid.toLowerCase() == serviceUuid.toLowerCase(),
        orElse: () => throw Exception("ไม่พบ Service UUID ($serviceUuid) บนอุปกรณ์นี้")
      );
      
      final char = await service.getCharacteristic(charUuid.toLowerCase());
      
      final value = await char.readValue();
      final data = value.buffer.asUint8List();
      
      if (data.length >= 4) {
        int n = data[0];
        int p = data[1];
        int k = data[2];
        int moist = data[3];

        // ✅ เช็กข้อมูลซ้ำ (Stale Data Guard)
        if (_lastSavedData != null &&
            n == _lastSavedData!['n'] &&
            p == _lastSavedData!['p'] &&
            k == _lastSavedData!['k'] &&
            moist == _lastSavedData!['moisture']) {
          
          return {'n': 0, 'p': 0, 'k': 0, 'moisture': 0, 'isStale': 1};
        }

        return {'n': n, 'p': p, 'k': k, 'moisture': moist, 'isStale': 0};
      } else {
        throw Exception("ข้อมูลที่ส่งมาไม่ครบ 4 ไบต์ (ได้มา ${data.length} ไบต์)");
      }
    } catch (e) {
      debugPrint('[BLE Web] Read Error: $e');
      throw Exception("Bluefy Error: $e");
    } finally {
      _isManualReading = false;
    }
  }
}

Future<void> showBluetoothScanDialog({
  required BuildContext context,
  required VoidCallback onConnected,
  required VoidCallback onDisconnected,
}) async {
  final isAvailable = await FlutterWebBluetooth.instance.isAvailable.first;
  if (!isAvailable) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("เบราว์เซอร์นี้ไม่รองรับบลูทูธ (แนะนำให้ใช้ Bluefy หรือ Chrome)"), backgroundColor: Colors.orange),
    );
    return;
  }

  try {
    final device = await FlutterWebBluetooth.instance.requestDevice(
      RequestOptionsBuilder([
        RequestFilterBuilder(services: ["4fafc201-1fb5-459e-8fcc-c5c9c331914b"])
      ]),
    );

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    await BLEService().connect(device, onDisconnected: onDisconnected);

    if (context.mounted) {
      Navigator.pop(context);
      onConnected();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("เชื่อมต่อสำเร็จ"), backgroundColor: Colors.green));
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ยกเลิกหรือเชื่อมต่อไม่ได้"), backgroundColor: Colors.red));
    }
  }
}