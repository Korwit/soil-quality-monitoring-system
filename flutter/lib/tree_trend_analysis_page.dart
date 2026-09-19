import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class TreeTrendAnalysisPage extends StatefulWidget {
  final String gardenId;
  final String gardenName;
  final List<String> selectedRoundIds;

  const TreeTrendAnalysisPage({
    super.key,
    required this.gardenId,
    required this.gardenName,
    required this.selectedRoundIds,
  });

  @override
  State<TreeTrendAnalysisPage> createState() => _TreeTrendAnalysisPageState();
}

class _TreeTrendAnalysisPageState extends State<TreeTrendAnalysisPage> {
  bool _isLoading = true;
  List<TreeCluster> _treeClusters = [];

  // ตัวแปรสำหรับควบคุมแผนที่
  final MapController _mapController = MapController();
  bool _mapExpanded = true; 

  // ตัวแปรควบคุมการพับหน้าจอ (UI State)
  bool _isSettingsExpanded = true; 
  bool _aiExpanded = false;

  // ตัวแปรค่าเป้าหมาย (Expected NPK)
  final TextEditingController _expectedNController = TextEditingController(text: '30');
  final TextEditingController _expectedPController = TextEditingController(text: '30');
  final TextEditingController _expectedKController = TextEditingController(text: '30');

  // ตัวแปร AI Chat
  final TextEditingController _chatInputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _isAiLoading = false;

  int get _expectedN => int.tryParse(_expectedNController.text) ?? 0;
  int get _expectedP => int.tryParse(_expectedPController.text) ?? 0;
  int get _expectedK => int.tryParse(_expectedKController.text) ?? 0;

  @override
  void initState() {
    super.initState();
    _fetchAndClusterData();
  }

  @override
  void dispose() {
    _expectedNController.dispose();
    _expectedPController.dispose();
    _expectedKController.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  // ==========================================
  // 1. ดึงข้อมูลและจัดกลุ่มรายต้น (Clustering Algorithm)
  // ==========================================
  Future<void> _fetchAndClusterData() async {
    setState(() => _isLoading = true);
    try {
      List<PointSnapshot> allPoints = [];

      // ดึงข้อมูลจุดตรวจทั้งหมดจากทุกรอบที่เลือก
      for (String roundId in widget.selectedRoundIds) {
        var roundDoc = await FirebaseFirestore.instance
            .collection('gardens')
            .doc(widget.gardenId)
            .collection('inspections')
            .doc(roundId)
            .get();
            
        String roundName = roundDoc.data()?['display_date'] ?? 'ไม่ทราบรอบ';
        DateTime roundDate = (roundDoc.data()?['created_at'] as Timestamp?)?.toDate() ?? DateTime.now();

        var pointsSnapshot = await roundDoc.reference.collection('points').orderBy('timestamp').get();
        for (var doc in pointsSnapshot.docs) {
          allPoints.add(PointSnapshot(
            roundId: roundId,
            roundName: roundName,
            roundDate: roundDate,
            lat: doc['latitude'],
            lng: doc['longitude'],
            n: doc['n_value'] ?? 0,
            p: doc['p_value'] ?? 0,
            k: doc['k_value'] ?? 0,
            timestamp: (doc['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
          ));
        }
      }

      // เรียงตามเวลาเก่าไปใหม่
      allPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // จัดกลุ่มเป็นรายต้น (พิกัดห่างกันไม่เกิน 3 เมตร ถือเป็นต้นเดียวกัน)
      List<TreeCluster> clusters = [];
      double distanceThreshold = 3.0; 

      for (var point in allPoints) {
        bool foundCluster = false;
        for (var cluster in clusters) {
          double distance = Geolocator.distanceBetween(
            cluster.centerLat, cluster.centerLng, 
            point.lat, point.lng
          );
          if (distance <= distanceThreshold) {
            cluster.history.add(point);
            foundCluster = true;
            break;
          }
        }
        if (!foundCluster) {
          clusters.add(TreeCluster(
            treeId: "T${clusters.length + 1}",
            centerLat: point.lat,
            centerLng: point.lng,
            history: [point],
          ));
        }
      }

      if (mounted) {
        setState(() {
          _treeClusters = clusters;
          _isLoading = false;
        });

        // พอโหลดข้อมูลเสร็จ เลื่อนแผนที่ไปที่ต้นไม้ต้นแรก (ถ้ามี)
        if (clusters.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try { 
              _mapController.move(LatLng(clusters.first.centerLat, clusters.first.centerLng), 17.0); 
            } catch (_) {}
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  // ==========================================
  // 2. ระบบ AI วิเคราะห์รายต้น
  // ==========================================
  Future<void> _sendChat(String userText) async {
    if (userText.trim().isEmpty) return;

    setState(() {
      _chatMessages.add({'text': userText, 'isUser': true});
      _isAiLoading = true;
    });
    _chatInputController.clear();
    _scrollChatToBottom();

    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-3.5-flash',
        systemInstruction: Content.system(_buildAIContext()),
      );

      final history = _chatMessages
          .take(_chatMessages.length - 1)
          .map((m) => m['isUser'] 
              ? Content.text(m['text']) 
              : Content.model([TextPart(m['text'])]))
          .toList();

      final chat = model.startChat(history: history);
      final response = await chat.sendMessage(Content.text(userText));

      if (mounted) {
        setState(() {
          _chatMessages.add({'text': response.text ?? 'ไม่มีการตอบกลับจาก AI', 'isUser': false});
          _isAiLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _chatMessages.add({'text': 'เกิดข้อผิดพลาด: $e', 'isUser': false});
          _isAiLoading = false;
        });
      }
    }
    _scrollChatToBottom();
  }

  String _buildAIContext() {
    String treesData = "";
    for (var tree in _treeClusters) {
      if (tree.history.length > 1) { 
        treesData += "ต้น ${tree.treeId} (พิกัด: ${tree.centerLat.toStringAsFixed(4)}, ${tree.centerLng.toStringAsFixed(4)}):\n";
        for (var h in tree.history) {
          treesData += " - ${h.roundName}: N=${h.n}, P=${h.p}, K=${h.k}\n";
        }
      }
    }

    return '''
คุณคือนักวิชาการเกษตร AI วิเคราะห์สุขภาพดินในสวนผลไม้/ทุเรียน
เป้าหมายสารอาหารที่คาดหวัง: N=$_expectedN, P=$_expectedP, K=$_expectedK
ข้อมูลการเปลี่ยนแปลงสารอาหารรายต้น (เฉพาะต้นที่มีประวัติการตรวจมากกว่า 1 ครั้ง):
$treesData

ผู้ใช้งานจะถามคำถามเกี่ยวกับแนวโน้มดิน ช่วยวิเคราะห์หาสาเหตุที่ค่า NPK ผิดปกติหรือแกว่ง และให้คำแนะนำการจัดการดินในพิกัดนั้นอย่างตรงจุด
''';
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ==========================================
  // 3. การสร้าง UI หน้าจอ
  // ==========================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text("วิเคราะห์แนวโน้มรายต้น"), 
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildExpectedNPKInputs(),
                
                // ถ้าย่อแชท AI ไว้ และมีข้อมูลต้นไม้ ให้แสดงแผนที่
                if (!_aiExpanded && _treeClusters.isNotEmpty)
                  _buildMapSection(),

                // ใช้ Expanded ครอบทั้งรายการต้นไม้และ AI
                Expanded(
                  child: Column(
                    children: [
                      // ถ้าย่อแชท AI ไว้ -> ให้แสดงรายการพิกัดต้นไม้
                      if (!_aiExpanded)
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: _treeClusters.length,
                            itemBuilder: (context, index) {
                              return _buildTreeCard(_treeClusters[index]);
                            },
                          ),
                        ),
                      
                      // ส่วน AI Chat (จะขยายเต็มพื้นที่ถ้า _aiExpanded = true)
                      _buildAIChatSection(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // ==========================================
  // วิดเจ็ต: แผนที่ (ใหม่)
  // ==========================================
  Widget _buildMapSection() {
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _mapExpanded = !_mapExpanded),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.map, color: Colors.deepPurple, size: 18),
                const SizedBox(width: 8),
                const Text("แผนที่ตำแหน่งต้นไม้", style: TextStyle(color: Colors.deepPurple, fontWeight: FontWeight.bold)),
                const Spacer(),
                Icon(_mapExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.deepPurple),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: SizedBox(
            height: MediaQuery.of(context).size.height * 0.30, 
            child: _buildMap(),
          ),
          secondChild: const SizedBox.shrink(),
          crossFadeState: _mapExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 250),
        ),
      ],
    );
  }

  Widget _buildMap() {
    List<Marker> markers = [];
    
    // สร้าง Marker ให้แต่ละต้นไม้
    for (var tree in _treeClusters) {
      bool hasHistory = tree.history.length > 1; // เช็คว่ามีประวัติหลายรอบไหม
      
      markers.add(
        Marker(
          point: LatLng(tree.centerLat, tree.centerLng),
          width: 45,
          height: 45,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasHistory ? Colors.deepPurple.withOpacity(0.85) : Colors.grey.withOpacity(0.85),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 2))
              ]
            ),
            alignment: Alignment.center,
            child: Text(
              tree.treeId, // "T1", "T2" ฯลฯ
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ),
      );
    }

    // จุดศูนย์กลางเริ่มต้น (กันเหนียวเผื่อบัค MapController)
    LatLng center = _treeClusters.isNotEmpty 
        ? LatLng(_treeClusters.first.centerLat, _treeClusters.first.centerLng) 
        : const LatLng(13.7563, 100.5018);

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center, 
        initialZoom: 17.0,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', 
          userAgentPackageName: 'com.example.soil_app'
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  // ส่วนตั้งค่าเป้าหมายที่พับได้
  Widget _buildExpectedNPKInputs() {
    return Container(
      color: Colors.deepPurple,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _isSettingsExpanded = !_isSettingsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.tune, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "ตั้งค่าเป้าหมาย NPK",
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Icon(
                    _isSettingsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: _buildSettingsContent(),
            secondChild: const SizedBox.shrink(),
            crossFadeState: _isSettingsExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsContent() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          const Text("เป้าหมาย: ", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(child: _buildTextField("N", _expectedNController, Colors.blue)),
          const SizedBox(width: 8),
          Expanded(child: _buildTextField("P", _expectedPController, Colors.green)),
          const SizedBox(width: 8),
          Expanded(child: _buildTextField("K", _expectedKController, Colors.orange)),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.deepPurple),
            tooltip: "คำนวณใหม่",
            onPressed: () {
              setState(() {
                _isSettingsExpanded = false; // ปิดกล่องเมื่อกดโหลด
              });
            }, 
          )
        ],
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController ctrl, Color color) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  // การ์ดแสดงผลรายต้น
  Widget _buildTreeCard(TreeCluster tree) {
    bool hasHistory = tree.history.length > 1;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        title: Text("จุดตรวจ: ${tree.treeId}", style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text("พิกัด: ${tree.centerLat.toStringAsFixed(5)}, ${tree.centerLng.toStringAsFixed(5)} (${tree.history.length} รอบ)"),
        leading: CircleAvatar(
          backgroundColor: hasHistory ? Colors.deepPurple[100] : Colors.grey[200],
          child: Text(
            tree.treeId, // ใส่ชื่อต้นไม้ T1, T2 ไว้ในไอคอนด้วย
            style: TextStyle(
              color: hasHistory ? Colors.deepPurple : Colors.grey[700], 
              fontWeight: FontWeight.bold, fontSize: 12
            ),
          ),
        ),
        initiallyExpanded: hasHistory,
        children: tree.history.map((point) {
          int index = tree.history.indexOf(point);
          String trendIcon = "";
          Color trendColor = Colors.grey;

          if (index > 0) {
            int prevN = tree.history[index - 1].n;
            if (point.n > prevN) { trendIcon = "▲ เพิ่มขึ้น"; trendColor = Colors.green; } 
            else if (point.n < prevN) { trendIcon = "▼ ลดลง"; trendColor = Colors.red; } 
            else { trendIcon = "- คงที่"; trendColor = Colors.grey; }
          } else {
            trendIcon = "จุดตั้งต้น";
          }

          return ListTile(
            title: Text("รอบ: ${point.roundName}", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            subtitle: Text("N: ${point.n} | P: ${point.p} | K: ${point.k}", style: const TextStyle(fontSize: 12)),
            trailing: Text(trendIcon, style: TextStyle(color: trendColor, fontWeight: FontWeight.bold, fontSize: 12)),
          );
        }).toList(),
      ),
    );
  }

  // ส่วนแชท AI ที่พับและขยายได้
  Widget _buildAIChatSection() {
    // 1. สร้างแถบกดหัวข้อ
    Widget header = InkWell(
      onTap: () {
        setState(() {
          _aiExpanded = !_aiExpanded;
          // ความฉลาด: ถ้าเปิดหน้าต่าง AI ให้พับส่วนตั้งค่า NPK และแผนที่ ด้านบนเก็บอัตโนมัติด้วย
          if (_aiExpanded) {
            _isSettingsExpanded = false;
            _mapExpanded = false;
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.deepPurple[50],
          border: Border(top: BorderSide(color: Colors.deepPurple.withOpacity(0.2))),
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, color: Colors.deepPurple, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                "ถามนักวิชาการ AI เรื่องแนวโน้มรายต้น",
                style: TextStyle(color: Colors.deepPurple, fontWeight: FontWeight.bold),
              ),
            ),
            Icon(
              _aiExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
              color: Colors.deepPurple,
            ),
          ],
        ),
      ),
    );

    // 2. สร้างกล่องแชท
    Widget chatBody = Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
      ),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _chatScrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _chatMessages.length + (_isAiLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _chatMessages.length && _isAiLoading) {
                  return const Align(
                    alignment: Alignment.centerLeft, 
                    child: Padding(
                      padding: EdgeInsets.all(8.0), 
                      child: CircularProgressIndicator()
                    )
                  );
                }
                var msg = _chatMessages[index];
                bool isUser = msg['isUser'];
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.deepPurple : Colors.grey[200],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(
                      msg['text'], 
                      style: TextStyle(color: isUser ? Colors.white : Colors.black87)
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatInputController,
                    decoration: InputDecoration(
                      hintText: "ถาม AI เช่น ต้น T1 ค่า N ลดลงเพราะอะไร?",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      filled: true,
                      fillColor: Colors.grey[100],
                    ),
                    onSubmitted: _isAiLoading ? null : _sendChat,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.deepPurple),
                  onPressed: _isAiLoading ? null : () => _sendChat(_chatInputController.text),
                )
              ],
            ),
          )
        ],
      ),
    );

    // 3. ควบคุมการแสดงผลแบบเต็มจอ
    if (_aiExpanded) {
      // โหมดขยาย: ยึดพื้นที่ Expanded ด้านบนทั้งหมด (รายการพิกัดจะหายไป)
      return Expanded(
        child: Column(
          children: [
            header,
            Expanded(child: chatBody), 
          ],
        ),
      );
    } else {
      // โหมดหด: โชว์แค่ Header แปะอยู่ขอบล่างสุด
      return Column(
        children: [
          header,
        ],
      );
    }
  }
}

// ==========================================
// Models สำหรับเก็บข้อมูล
// ==========================================
class PointSnapshot {
  final String roundId;
  final String roundName;
  final DateTime roundDate;
  final double lat;
  final double lng;
  final int n;
  final int p;
  final int k;
  final DateTime timestamp;

  PointSnapshot({
    required this.roundId, required this.roundName, required this.roundDate, 
    required this.lat, required this.lng, required this.n, required this.p, 
    required this.k, required this.timestamp
  });
}

class TreeCluster {
  final String treeId;
  final double centerLat;
  final double centerLng;
  final List<PointSnapshot> history;

  TreeCluster({
    required this.treeId, required this.centerLat, 
    required this.centerLng, required this.history
  });
}