import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'tree_trend_analysis_page.dart';
import 'package:csv/csv.dart';

// ✅ นำเข้าไฟล์ Export แบบแยกแพลตฟอร์ม
import 'csv_export_mobile.dart' if (dart.library.html) 'csv_export_web.dart';
import 'home_page.dart';

class InspectionDatesPage extends StatelessWidget {
  final String gardenId;
  final String gardenName;
  final String userRole;

  const InspectionDatesPage({
    super.key,
    required this.gardenId,
    required this.gardenName,
    required this.userRole,
  });

  String _formatThaiDate(DateTime date) {
    int thaiYear = date.year + 543;
    return '${DateFormat('dd/MM').format(date)}/$thaiYear';
  }

  Future<void> _processExport(BuildContext context, List<QueryDocumentSnapshot> selectedDocs) async {
    if (selectedDocs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("กรุณาเลือกอย่างน้อย 1 รอบ")));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );

    try {
      List<List<dynamic>> allRows = [];
      allRows.add(["สวน: $gardenName"]);
      allRows.add(["วันที่ทำรายการ: ${_formatThaiDate(DateTime.now())}"]);
      allRows.add([]);

      for (var doc in selectedDocs) {
        String roundName = doc['display_date'];
        allRows.add(["=== รอบตรวจ: $roundName ==="]);
        allRows.add(["วันที่", "เวลา", "Latitude", "Longitude", "N", "P", "K", "ความชื้น", "ที่มา"]);

        var pointsSnapshot = await doc.reference
            .collection('points')
            .orderBy('timestamp', descending: false)
            .get();

        if (pointsSnapshot.docs.isEmpty) {
          allRows.add(["(ไม่มีข้อมูลจุดตรวจในรอบนี้)"]);
        } else {
          for (var point in pointsSnapshot.docs) {
            Map<String, dynamic> data = point.data();
            DateTime? dt = (data['timestamp'] as Timestamp?)?.toDate();
            
            String dStr = dt != null ? DateFormat('dd/MM/yyyy').format(dt) : "-";
            String tStr = dt != null ? DateFormat('HH:mm:ss').format(dt) : "-";

            allRows.add([
              dStr,
              tStr,
              data['latitude'],
              data['longitude'],
              data['n_value'] ?? 0,
              data['p_value'] ?? 0,
              data['k_value'] ?? 0,
              data['moisture'] ?? 0,
              data['source'] ?? 'Manual'
            ]);
          }
        }
        allRows.add([]);
        allRows.add([]);
      }

      String csvData = const ListToCsvConverter().convert(allRows);
      String safeName = gardenName.replaceAll(' ', '_');
      String fileName = "${safeName}_${DateTime.now().millisecondsSinceEpoch}.csv";
      
      // ✅ เรียกใช้ฟังก์ชันที่แยกไฟล์ Web/Mobile ไว้
      await exportCSV(fileName, csvData);

      if (context.mounted) Navigator.pop(context);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(kIsWeb ? "กำลังดาวน์โหลดไฟล์ลงเครื่อง..." : "บันทึกไฟล์เรียบร้อยที่โฟลเดอร์ Downloads"),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(label: "ตกลง", textColor: Colors.white, onPressed: (){}),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  void _showMultiSelectExportDialog(BuildContext parentContext, List<QueryDocumentSnapshot> allDocs) {
    Set<String> selectedIds = {}; 

    showDialog(
      context: parentContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (builderContext, setStateDialog) {
            return AlertDialog(
              title: const Text("เลือกรอบตรวจที่ต้องการ"),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            setStateDialog(() {
                              if (selectedIds.length == allDocs.length) {
                                selectedIds.clear();
                              } else {
                                selectedIds = allDocs.map((e) => e.id).toSet();
                              }
                            });
                          },
                          child: Text(selectedIds.length == allDocs.length ? "ยกเลิกทั้งหมด" : "เลือกทั้งหมด"),
                        )
                      ],
                    ),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: allDocs.length,
                        itemBuilder: (ctx, index) {
                          var doc = allDocs[index];
                          bool isChecked = selectedIds.contains(doc.id);
                          return CheckboxListTile(
                            title: Text(doc['display_date']),
                            value: isChecked,
                            activeColor: Colors.green,
                            onChanged: (bool? val) {
                              setStateDialog(() {
                                if (val == true) {
                                  selectedIds.add(doc.id);
                                } else {
                                  selectedIds.remove(doc.id);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text("ยกเลิก")
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    List<QueryDocumentSnapshot> selectedDocs = allDocs
                        .where((doc) => selectedIds.contains(doc.id))
                        .toList();
                    _processExport(parentContext, selectedDocs);
                  },
                  child: Text("ดาวน์โหลด (${selectedIds.length})"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleExportAction(BuildContext context, String action) async {
    var snapshot = await FirebaseFirestore.instance
        .collection('gardens').doc(gardenId)
        .collection('inspections')
        .orderBy('created_at', descending: true)
        .get();

    if (snapshot.docs.isEmpty) {
      if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ไม่มีข้อมูลรอบตรวจ")));
      return;
    }

    if (!context.mounted) return;

    if (action == 'all') {
      _processExport(context, snapshot.docs);
    } else if (action == 'select') {
      _showMultiSelectExportDialog(context, snapshot.docs);
    }
  }

  void _showDateDialog(BuildContext context, {String? docId, DateTime? initialStart, DateTime? initialEnd}) {
    DateTime startDate = initialStart ?? DateTime.now();
    DateTime endDate = initialEnd ?? DateTime.now();
    bool isTodayChecked = (docId == null); 

    TextEditingController startCtrl = TextEditingController(text: _formatThaiDate(startDate));
    TextEditingController endCtrl = TextEditingController(text: _formatThaiDate(endDate));

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            Future<void> selectDate(bool isStart) async {
              DateTime initial = isStart ? startDate : endDate;
              DateTime? picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
                locale: const Locale('th', 'TH'), 
              );

              if (picked != null) {
                setStateDialog(() {
                  isTodayChecked = false;
                  if (isStart) {
                    startDate = picked;
                    startCtrl.text = _formatThaiDate(startDate);
                    if (startDate.isAfter(endDate)) {
                      endDate = startDate;
                      endCtrl.text = _formatThaiDate(endDate);
                    }
                  } else {
                    endDate = picked;
                    endCtrl.text = _formatThaiDate(endDate);
                    if (endDate.isBefore(startDate)) {
                      startDate = endDate;
                      startCtrl.text = _formatThaiDate(startDate);
                    }
                  }
                });
              }
            }

            return AlertDialog(
              title: Text(docId == null ? "เพิ่มรอบการตรวจ" : "แก้ไขรอบการตรวจ"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: startCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(labelText: "วันที่เริ่ม", prefixIcon: Icon(Icons.calendar_today, color: Colors.green)),
                    onTap: () => selectDate(true),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: endCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(labelText: "วันที่สิ้นสุด", prefixIcon: Icon(Icons.event, color: Colors.orange)),
                    onTap: () => selectDate(false),
                  ),
                  CheckboxListTile(
                    title: const Text("วันนี้ (Today)"),
                    value: isTodayChecked,
                    onChanged: (bool? value) {
                      setStateDialog(() {
                        isTodayChecked = value ?? false;
                        if (isTodayChecked) {
                          DateTime now = DateTime.now();
                          startDate = now; endDate = now;
                          startCtrl.text = _formatThaiDate(now);
                          endCtrl.text = _formatThaiDate(now);
                        }
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("ยกเลิก")),
                ElevatedButton(
                  onPressed: () async {
                    String displayDate = (startCtrl.text == endCtrl.text) ? startCtrl.text : "${startCtrl.text} - ${endCtrl.text}";
                    String targetId = docId ?? "${startDate.millisecondsSinceEpoch}";
                    Map<String, dynamic> data = {
                      'start_date': Timestamp.fromDate(startDate),
                      'end_date': Timestamp.fromDate(endDate),
                      'display_date': displayDate,
                    };
                    if (docId == null) data['created_at'] = FieldValue.serverTimestamp();
                    
                    await FirebaseFirestore.instance
                        .collection('gardens').doc(gardenId)
                        .collection('inspections').doc(targetId)
                        .set(data, SetOptions(merge: true));

                    if (context.mounted) {
                      Navigator.pop(context); 
                      if (docId == null) {
                        Navigator.push(context, MaterialPageRoute(builder: (context) => HomePage(gardenId: gardenId, inspectionDateId: targetId, userRole: userRole)));
                      }
                    }
                  },
                  child: Text(docId == null ? "สร้าง" : "บันทึก"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ฟังก์ชันแสดง Popup เลือกรอบการตรวจเพื่อวิเคราะห์
  void _showMultiRoundAnalysisDialog(BuildContext parentContext, List<QueryDocumentSnapshot> allDocs) {
    Set<String> selectedIds = {};

    showDialog(
      context: parentContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (builderContext, setStateDialog) {
            return AlertDialog(
              title: const Text("เลือกรอบตรวจเพื่อเปรียบเทียบ"),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: Column(
                  children: [
                    const Text("เลือกอย่างน้อย 2 รอบเพื่อดูแนวโน้มรายต้น", style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: allDocs.length,
                        itemBuilder: (ctx, index) {
                          var doc = allDocs[index];
                          bool isChecked = selectedIds.contains(doc.id);
                          return CheckboxListTile(
                            title: Text("รอบ: ${doc['display_date']}"),
                            value: isChecked,
                            activeColor: Colors.deepPurple,
                            onChanged: (bool? val) {
                              setStateDialog(() {
                                if (val == true) selectedIds.add(doc.id);
                                else selectedIds.remove(doc.id);
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("ยกเลิก")),
                ElevatedButton(
                  onPressed: selectedIds.length < 2 ? null : () {
                    Navigator.pop(dialogContext);
                    // ส่งข้อมูลไปยังหน้าวิเคราะห์รายต้น
                    Navigator.push(parentContext, MaterialPageRoute(
                      builder: (context) => TreeTrendAnalysisPage(
                        gardenId: gardenId,
                        gardenName: gardenName,
                        selectedRoundIds: selectedIds.toList(),
                      )
                    ));
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
                  child: Text("เริ่มวิเคราะห์ (${selectedIds.length})"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _deleteInspectionDate(BuildContext context, String dateId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("ยืนยันการลบ"),
        content: const Text("ข้อมูลในรอบนี้จะหายไปทั้งหมด"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("ยกเลิก")),
          TextButton(
            onPressed: () async {
              await FirebaseFirestore.instance.collection('gardens').doc(gardenId).collection('inspections').doc(dateId).delete();
              if (context.mounted) Navigator.pop(context); 
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("ลบ"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isOwner = (userRole == 'owner');

    return Scaffold(
      appBar: AppBar(
        title: Text("รอบการตรวจ: $gardenName"),
        backgroundColor: Colors.green[700],
        actions: [
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('gardens').doc(gardenId)
                .collection('inspections')
                .orderBy('created_at', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              return IconButton(
                icon: const Icon(Icons.analytics_outlined),
                tooltip: "วิเคราะห์เปรียบเทียบรอบตรวจ",
                onPressed: () {
                  if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
                    _showMultiRoundAnalysisDialog(context, snapshot.data!.docs);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ไม่มีรอบการตรวจให้วิเคราะห์")));
                  }
                },
              );
            }
          ),
          PopupMenuButton<String>(
            onSelected: (value) => _handleExportAction(context, value),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'select',
                child: Row(children: [Icon(Icons.check_box_outlined, color: Colors.green), SizedBox(width: 10), Text('เลือกเพื่อโหลดลงเครื่อง')]),
              ),
              const PopupMenuItem<String>(
                value: 'all',
                child: Row(children: [Icon(Icons.file_download, color: Colors.blue), SizedBox(width: 10), Text('ดาวน์โหลดทั้งหมด')]),
              ),
            ],
          ),
        ],
      ),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance
            .collection('gardens').doc(gardenId)
            .collection('inspections')
            .orderBy('created_at', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          var docs = snapshot.data!.docs;
          if (docs.isEmpty) return const Center(child: Text("กด + เพื่อเริ่มรอบตรวจใหม่"));

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              var data = docs[index].data();
              String dateId = docs[index].id;
              
              DateTime? startDate = (data['start_date'] as Timestamp?)?.toDate();
              DateTime? endDate = (data['end_date'] as Timestamp?)?.toDate();

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: ListTile(
                  leading: const Icon(Icons.date_range, color: Colors.green, size: 30),
                  title: Text("รอบ: ${data['display_date']}", style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text("แตะเพื่อดูจุดตรวจ"),
                  trailing: isOwner 
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.edit, color: Colors.orange), onPressed: () => _showDateDialog(context, docId: dateId, initialStart: startDate, initialEnd: endDate)),
                        IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deleteInspectionDate(context, dateId)),
                        const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                      ])
                    : const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => HomePage(gardenId: gardenId, inspectionDateId: dateId, userRole: userRole))),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showDateDialog(context),
        label: const Text("เพิ่มรอบตรวจ"),
        icon: const Icon(Icons.add),
        backgroundColor: Colors.green,
      ),
    );
  }
}