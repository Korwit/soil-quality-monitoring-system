import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'soil_chart_dialog.dart';
import 'package:flutter/services.dart';

class SoilAnalysisPage extends StatefulWidget {
  final String gardenId;
  final String inspectionDateId;
  final String userRole; 

  const SoilAnalysisPage({
    super.key,
    required this.gardenId,
    required this.inspectionDateId,
    required this.userRole, 
  });

  @override
  State<SoilAnalysisPage> createState() => _SoilAnalysisPageState();
}

class _SoilAnalysisPageState extends State<SoilAnalysisPage> {
  final MapController _mapController = MapController();

  final TextEditingController _expectedNController = TextEditingController(text: '30');
  final TextEditingController _expectedPController = TextEditingController(text: '30');
  final TextEditingController _expectedKController = TextEditingController(text: '30');
  final TextEditingController _chatInputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  double _tolerance = 40.0;
  bool _inputExpanded = true;
  bool _mapExpanded = true; 

  List<_PointData> _points = [];
  bool _isLoading = false;
  bool _hasAnalyzed = false;

  List<_ChatMessage> _chatMessages = [];
  bool _isAiLoading = false;

  String? _currentAnalysisId;
  String _currentAnalysisName = "การวิเคราะห์เริ่มต้น";
  List<Map<String, dynamic>> _savedAnalyses = [];

  int get _expectedN => int.tryParse(_expectedNController.text) ?? 0;
  int get _expectedP => int.tryParse(_expectedPController.text) ?? 0;
  int get _expectedK => int.tryParse(_expectedKController.text) ?? 0;

  double get _avgN => _points.isEmpty ? 0 : _points.map((p) => p.n).reduce((a, b) => a + b) / _points.length;
  double get _avgP => _points.isEmpty ? 0 : _points.map((p) => p.p).reduce((a, b) => a + b) / _points.length;
  double get _avgK => _points.isEmpty ? 0 : _points.map((p) => p.k).reduce((a, b) => a + b) / _points.length;
  double get _avgMoisture => _points.isEmpty ? 0 : _points.map((p) => p.moisture).reduce((a, b) => a + b) / _points.length;

  @override
  void initState() {
    super.initState();
    _fetchAnalyses();
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
  // 🗄️ Database Functions
  // ==========================================
  Future<void> _fetchAnalyses() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('gardens')
        .doc(widget.gardenId)
        .collection('inspections')
        .doc(widget.inspectionDateId)
        .collection('analyses')
        .orderBy('created_at', descending: true)
        .get();

    if (mounted) {
      setState(() {
        _savedAnalyses = snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
      });
    }
  }

  Future<void> _saveAnalysisProfile() async {
    TextEditingController nameCtrl = TextEditingController(text: _currentAnalysisId == null ? "" : _currentAnalysisName);
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_currentAnalysisId == null ? "บันทึกการวิเคราะห์ใหม่" : "อัปเดตการวิเคราะห์"),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: "ชื่อโปรไฟล์ (เช่น สำหรับทุเรียน)"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ยกเลิก")),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (nameCtrl.text.trim().isEmpty) return;

              final data = {
                'name': nameCtrl.text.trim(),
                'expected_n': _expectedN,
                'expected_p': _expectedP,
                'expected_k': _expectedK,
                'tolerance': _tolerance,
                'chat_history': _chatMessages.map((m) => m.toMap()).toList(),
                'created_at': FieldValue.serverTimestamp(),
              };

              final ref = FirebaseFirestore.instance
                  .collection('gardens')
                  .doc(widget.gardenId)
                  .collection('inspections')
                  .doc(widget.inspectionDateId)
                  .collection('analyses');

              if (_currentAnalysisId == null) {
                final doc = await ref.add(data);
                await _fetchAnalyses();
                if (mounted) {
                  setState(() {
                    _currentAnalysisId = doc.id;
                    _currentAnalysisName = nameCtrl.text.trim();
                  });
                }
              } else {
                await ref.doc(_currentAnalysisId).update(data);
                await _fetchAnalyses();
                if (mounted) {
                  setState(() => _currentAnalysisName = nameCtrl.text.trim());
                }
              }
              
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("บันทึกโปรไฟล์สำเร็จ")));
            },
            child: const Text("บันทึก"),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAnalysisProfile() async {
    if (_currentAnalysisId == null) return;
    await FirebaseFirestore.instance
        .collection('gardens')
        .doc(widget.gardenId)
        .collection('inspections')
        .doc(widget.inspectionDateId)
        .collection('analyses')
        .doc(_currentAnalysisId)
        .delete();
    
    await _fetchAnalyses();
    if (mounted) {
      setState(() {
        _currentAnalysisId = null;
        _currentAnalysisName = "การวิเคราะห์เริ่มต้น";
        _chatMessages.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ลบโปรไฟล์แล้ว")));
    }
  }

  void _loadProfile(Map<String, dynamic> profile) {
    setState(() {
      _currentAnalysisId = profile['id'];
      _currentAnalysisName = profile['name'];
      _expectedNController.text = profile['expected_n'].toString();
      _expectedPController.text = profile['expected_p'].toString();
      _expectedKController.text = profile['expected_k'].toString();
      _tolerance = (profile['tolerance'] as num).toDouble();
      
      if (profile['chat_history'] != null) {
        _chatMessages = (profile['chat_history'] as List).map((m) => _ChatMessage.fromMap(m)).toList();
      } else {
        _chatMessages.clear();
      }
    });
    _runAnalysis(); 
  }

  // ==========================================
  // 🤖 AI Chat & Logic Functions
  // ==========================================
  Future<void> _updateChatHistoryToDB() async {
    if (_currentAnalysisId != null) {
      await FirebaseFirestore.instance
          .collection('gardens')
          .doc(widget.gardenId)
          .collection('inspections')
          .doc(widget.inspectionDateId)
          .collection('analyses')
          .doc(_currentAnalysisId)
          .update({
        'chat_history': _chatMessages.map((m) => m.toMap()).toList()
      });
    }
  }

  Future<void> _startNewChat() async {
    setState(() {
      _chatMessages.clear();
    });
    await _updateChatHistoryToDB();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("เริ่มแชทใหม่แล้ว")));
  }

  Future<void> _sendChat(String userText) async {
    if (userText.trim().isEmpty) return;

    setState(() {
      _chatMessages.add(_ChatMessage(text: userText, isUser: true));
      _isAiLoading = true;
    });
    _chatInputController.clear();
    _scrollChatToBottom();

    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-3.5-flash',
        systemInstruction: Content.system(_buildSoilContext()),
      );

      final history = _chatMessages
          .where((m) => !m.isLoading && !m.isError)
          .take(_chatMessages.length - 1)
          .map((m) => m.isUser ? Content.text(m.text) : Content.model([TextPart(m.text)]))
          .toList();

      final chat = model.startChat(history: history);
      final response = await chat.sendMessage(Content.text(userText));

      if (mounted) {
        setState(() {
          _chatMessages.add(_ChatMessage(text: response.text ?? 'ไม่ได้รับผลจาก AI', isUser: false));
          _isAiLoading = false;
        });
      }
      await _updateChatHistoryToDB();

    } catch (e) {
      if (mounted) {
        setState(() {
          _chatMessages.add(_ChatMessage(text: 'เกิดข้อผิดพลาด: $e', isUser: false, isError: true));
          _isAiLoading = false;
        });
      }
    }
    _scrollChatToBottom();
  }

  Future<void> _analyzeWithAI() async {
    await _sendChat('วิเคราะห์สภาพดินโดยรวมและให้คำแนะนำการปรับปรุงดินและการใส่ปุ๋ยที่เหมาะสม พร้อมบอกผลกระทบต่อพืชและข้อควรระวัง ความยาวไม่เกิน 200 คำ');
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
  // 📊 Core Logic Functions
  // ==========================================
  _PointStatus _evaluatePoint(_PointData p) {
    if (_expectedN == 0 && _expectedP == 0 && _expectedK == 0) return _PointStatus.neutral;
    double scoreN = _expectedN > 0 ? p.n / _expectedN : 1.0;
    double scoreP = _expectedP > 0 ? p.p / _expectedP : 1.0;
    double scoreK = _expectedK > 0 ? p.k / _expectedK : 1.0;
    double tLow = 1.0 - (_tolerance / 100);
    double tHigh = 1.0 + (_tolerance / 100);
    bool nOk = _expectedN == 0 || (scoreN >= tLow && scoreN <= tHigh);
    bool pOk = _expectedP == 0 || (scoreP >= tLow && scoreP <= tHigh);
    bool kOk = _expectedK == 0 || (scoreK >= tLow && scoreK <= tHigh);
    int okCount = [nOk, pOk, kOk].where((b) => b).length;
    if (okCount == 3) return _PointStatus.good;
    if (okCount == 2) return _PointStatus.warning;
    return _PointStatus.bad;
  }

  List<_FertilizerAdvice> _getFertilizerAdvices() {
    if (_points.isEmpty) return [];
    final List<_FertilizerAdvice> advices = [];
    final double tLow = 1.0 - (_tolerance / 100);
    final double tHigh = 1.0 + (_tolerance / 100);

    if (_expectedN > 0) {
      final double ratioN = _avgN / _expectedN;
      if (ratioN < tLow) {
        final double deficit = _expectedN - _avgN;
        advices.add(_FertilizerAdvice(nutrient: 'N (ไนโตรเจน)', status: _NutrientStatus.low, avgValue: _avgN, expectedValue: _expectedN.toDouble(), fertilizerName: 'ยูเรีย (46-0-0)', fertilizerDetail: 'ปุ๋ยไนโตรเจนสูง เหมาะสำหรับเร่งการเจริญเติบโตและสีเขียวของใบ', dosageHint: 'ขาด N ประมาณ ${deficit.toStringAsFixed(1)} mg/kg — ควรใส่ยูเรียประมาณ ${(deficit * 2.17).toStringAsFixed(1)} kg/ไร่', color: Colors.blue));
      } else if (ratioN > tHigh) {
        advices.add(_FertilizerAdvice(nutrient: 'N (ไนโตรเจน)', status: _NutrientStatus.high, avgValue: _avgN, expectedValue: _expectedN.toDouble(), fertilizerName: '-', fertilizerDetail: 'ไม่ควรใส่ปุ๋ยไนโตรเจนเพิ่ม', dosageHint: 'ค่า N สูงเกินเกณฑ์ ควรงดปุ๋ยไนโตรเจนในรอบนี้ และเพิ่มการระบายน้ำ', color: Colors.orange));
      }
    }
    if (_expectedP > 0) {
      final double ratioP = _avgP / _expectedP;
      if (ratioP < tLow) {
        final double deficit = _expectedP - _avgP;
        advices.add(_FertilizerAdvice(nutrient: 'P (ฟอสฟอรัส)', status: _NutrientStatus.low, avgValue: _avgP, expectedValue: _expectedP.toDouble(), fertilizerName: 'DAP (18-46-0)', fertilizerDetail: 'ปุ๋ยฟอสฟอรัสสูง ช่วยพัฒนารากและการออกดอกติดผล', dosageHint: 'ขาด P ประมาณ ${deficit.toStringAsFixed(1)} mg/kg — ควรใส่ DAP ประมาณ ${(deficit * 2.17).toStringAsFixed(1)} kg/ไร่', color: Colors.green[700]!));
      } else if (ratioP > tHigh) {
        advices.add(_FertilizerAdvice(nutrient: 'P (ฟอสฟอรัส)', status: _NutrientStatus.high, avgValue: _avgP, expectedValue: _expectedP.toDouble(), fertilizerName: '-', fertilizerDetail: 'ไม่ควรใส่ปุ๋ยฟอสฟอรัสเพิ่ม', dosageHint: 'ค่า P สูงเกินเกณฑ์ อาจทำให้ดินแข็งและดูดซับธาตุเหล็กลดลง', color: Colors.orange));
      }
    }
    if (_expectedK > 0) {
      final double ratioK = _avgK / _expectedK;
      if (ratioK < tLow) {
        final double deficit = _expectedK - _avgK;
        advices.add(_FertilizerAdvice(nutrient: 'K (โพแทสเซียม)', status: _NutrientStatus.low, avgValue: _avgK, expectedValue: _expectedK.toDouble(), fertilizerName: 'MOP / โพแทสเซียมคลอไรด์ (0-0-60)', fertilizerDetail: 'ปุ๋ยโพแทสเซียมสูง ช่วยเพิ่มความแข็งแรงของลำต้นและคุณภาพผลผลิต', dosageHint: 'ขาด K ประมาณ ${deficit.toStringAsFixed(1)} mg/kg — ควรใส่ MOP ประมาณ ${(deficit * 1.67).toStringAsFixed(1)} kg/ไร่', color: Colors.orange[800]!));
      } else if (ratioK > tHigh) {
        advices.add(_FertilizerAdvice(nutrient: 'K (โพแทสเซียม)', status: _NutrientStatus.high, avgValue: _avgK, expectedValue: _expectedK.toDouble(), fertilizerName: '-', fertilizerDetail: 'ไม่ควรใส่ปุ๋ยโพแทสเซียมเพิ่ม', dosageHint: 'ค่า K สูงเกินเกณฑ์ อาจรบกวนการดูดซึม Mg และ Ca ของพืช', color: Colors.orange));
      }
    }
    return advices;
  }

  String _buildSoilContext() {
    final advices = _getFertilizerAdvices();
    final adviceSummary = advices.isEmpty ? 'ค่า NPK ทุกตัวอยู่ในเกณฑ์ปกติ' : advices.map((a) => '${a.nutrient}: เฉลี่ย ${a.avgValue.toStringAsFixed(1)} mg/kg (คาดหวัง ${a.expectedValue.toStringAsFixed(0)} mg/kg) — ${a.status == _NutrientStatus.low ? "ต่ำกว่าเกณฑ์" : "สูงกว่าเกณฑ์"}').join('\n');
    return '''
คุณเป็นนักวิชาการเกษตรผู้เชี่ยวชาญด้านการวิเคราะห์ดินและการจัดการธาตุอาหารพืช
ตอบเป็นภาษาไทย กระชับ เข้าใจง่ายสำหรับเกษตรกร

ข้อมูลผลการตรวจดินของผู้ใช้:
- จำนวนจุดตรวจ: ${_points.length} จุด
- ค่าเฉลี่ย N (ไนโตรเจน): ${_avgN.toStringAsFixed(1)} mg/kg (คาดหวัง $_expectedN mg/kg)
- ค่าเฉลี่ย P (ฟอสฟอรัส): ${_avgP.toStringAsFixed(1)} mg/kg (คาดหวัง $_expectedP mg/kg)
- ค่าเฉลี่ย K (โพแทสเซียม): ${_avgK.toStringAsFixed(1)} mg/kg (คาดหวัง $_expectedK mg/kg)
- ความชื้นเฉลี่ย: ${_avgMoisture.toStringAsFixed(1)}%
- ช่วง tolerance: ±${_tolerance.toInt()}%
- สรุปเบื้องต้น: $adviceSummary
''';
  }

  Future<void> _runAnalysis() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await FirebaseFirestore.instance.collection('gardens').doc(widget.gardenId).collection('inspections').doc(widget.inspectionDateId).collection('points').orderBy('timestamp', descending: false).get();

      List<_PointData> pts = [];
      for (var doc in snapshot.docs) {
        final d = doc.data();
        pts.add(_PointData(id: doc.id, lat: (d['latitude'] as num?)?.toDouble() ?? 0, lng: (d['longitude'] as num?)?.toDouble() ?? 0, n: (d['n_value'] as num?)?.toInt() ?? 0, p: (d['p_value'] as num?)?.toInt() ?? 0, k: (d['k_value'] as num?)?.toInt() ?? 0, moisture: (d['moisture'] as num?)?.toInt() ?? 0, timestamp: d['timestamp'] as Timestamp?, source: d['source'] as String? ?? '-'));
      }

      if (mounted) {
        setState(() {
          _points = pts;
          _isLoading = false;
          _hasAnalyzed = true;
          _inputExpanded = false;
        });
      }

      if (pts.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try { _mapController.move(LatLng(pts.first.lat, pts.first.lng), 16.0); } catch (_) {}
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("เกิดข้อผิดพลาด: $e"), backgroundColor: Colors.red));
      }
    }
  }

  Map<_PointStatus, int> get _summary {
    Map<_PointStatus, int> map = {_PointStatus.good: 0, _PointStatus.warning: 0, _PointStatus.bad: 0, _PointStatus.neutral: 0};
    for (var p in _points) { map[_evaluatePoint(p)] = (map[_evaluatePoint(p)] ?? 0) + 1; }
    return map;
  }

  Color _statusColor(_PointStatus s) {
    switch (s) {
      case _PointStatus.good: return Colors.green;
      case _PointStatus.warning: return Colors.orange;
      case _PointStatus.bad: return Colors.red;
      case _PointStatus.neutral: return Colors.grey;
    }
  }

  String _statusLabel(_PointStatus s) {
    switch (s) {
      case _PointStatus.good: return "ดี";
      case _PointStatus.warning: return "ปานกลาง";
      case _PointStatus.bad: return "ต้องปรับปรุง";
      case _PointStatus.neutral: return "ไม่ระบุ";
    }
  }

  IconData _statusIcon(_PointStatus s) {
    switch (s) {
      case _PointStatus.good: return Icons.check_circle;
      case _PointStatus.warning: return Icons.warning_amber_rounded;
      case _PointStatus.bad: return Icons.cancel;
      case _PointStatus.neutral: return Icons.help_outline;
    }
  }

  String _formatDateTime(Timestamp? ts) {
    if (ts == null) return "-";
    return DateFormat('dd/MM/yyyy HH:mm').format(ts.toDate());
  }

  // ==========================================
  // 🎨 UI Builders
  // ==========================================
  @override
  Widget build(BuildContext context) {
    final summary = _summary;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(title: const Text("วิเคราะห์ค่าดิน NPK"), backgroundColor: Colors.teal, elevation: 0),
      body: Column(
        children: [
          _buildCollapsibleInput(),
          if (_hasAnalyzed) ...[
            _buildMapSection(summary),
          ],
          if (_hasAnalyzed && _points.isNotEmpty)
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 20),
                children: [
                  _buildAvgCard(),
                  _buildFertilizerSection(),
                  _buildAISection(),
                  _buildPointList(),
                ],
              ),
            ),
          if (_hasAnalyzed && _points.isEmpty)
            const Expanded(child: Center(child: Text("ไม่มีข้อมูลจุดตรวจในรอบนี้", style: TextStyle(fontSize: 16, color: Colors.grey)))),
        ],
      ),
    );
  }

  Widget _buildMapSection(Map<_PointStatus, int> summary) {
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _mapExpanded = !_mapExpanded),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.map, color: Colors.teal, size: 18),
                const SizedBox(width: 8),
                const Text("แผนที่จุดตรวจ", style: TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                const Spacer(),
                Icon(_mapExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.teal),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: Column(
            children: [
              SizedBox(height: MediaQuery.of(context).size.height * 0.30, child: _buildMap()),
              _buildSummaryBar(summary),
            ],
          ),
          secondChild: const SizedBox.shrink(),
          crossFadeState: _mapExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 250),
        ),
      ],
    );
  }

  Widget _buildCollapsibleInput() {
    return Container(
      color: Colors.teal,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _inputExpanded = !_inputExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.tune, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "โปรไฟล์: $_currentAnalysisName",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Icon(_inputExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white70),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: _buildInputContent(),
            secondChild: const SizedBox.shrink(),
            crossFadeState: _inputExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }

  Widget _buildInputContent() {
    bool isOwner = (widget.userRole == 'owner');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_savedAnalyses.isNotEmpty) ...[
             Row(
               children: [
                 Expanded(
                   child: DropdownButtonFormField<String>(
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
                    ),
                    dropdownColor: Colors.teal[800],
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    value: _currentAnalysisId,
                    hint: const Text("เลือกโปรไฟล์การวิเคราะห์", style: TextStyle(color: Colors.white54)),
                    items: _savedAnalyses.map((e) => DropdownMenuItem(value: e['id'] as String, child: Text(e['name']))).toList(),
                    onChanged: (val) {
                      final profile = _savedAnalyses.firstWhere((e) => e['id'] == val);
                      _loadProfile(profile);
                    },
                   ),
                 ),
                 if (isOwner) ...[
                   const SizedBox(width: 8),
                   ElevatedButton(
                     onPressed: () {
                       setState(() {
                         _currentAnalysisId = null;
                         _currentAnalysisName = "การวิเคราะห์ใหม่";
                         _chatMessages.clear();
                       });
                     },
                     style: ElevatedButton.styleFrom(backgroundColor: Colors.white24, foregroundColor: Colors.white),
                     child: const Text("+ สร้าง"),
                   )
                 ]
               ],
             ),
             const SizedBox(height: 10),
          ],

          const Text("ค่า NPK ที่คาดหวัง (mg/kg)", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildNPKField("N (ไนโตรเจน)", _expectedNController, Colors.blue[200]!),
              const SizedBox(width: 8),
              _buildNPKField("P (ฟอสฟอรัส)", _expectedPController, Colors.green[200]!),
              const SizedBox(width: 8),
              _buildNPKField("K (โพแทสเซียม)", _expectedKController, Colors.orange[200]!),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text("ช่วงยอมรับ ±", style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(activeTrackColor: Colors.white, thumbColor: Colors.white, inactiveTrackColor: Colors.teal[300], overlayColor: Colors.white24),
                  child: Slider(value: _tolerance, min: 5, max: 80, divisions: 15, onChanged: (v) => setState(() => _tolerance = v)),
                ),
              ),
              Text("${_tolerance.toInt()}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _runAnalysis,
                  icon: _isLoading ? const SizedBox(width:18, height:18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.teal)) : const Icon(Icons.analytics),
                  label: Text(_isLoading ? "กำลังวิเคราะห์..." : "วิเคราะห์ผลดิน"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.teal[800], padding: const EdgeInsets.symmetric(vertical: 12), textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
              if (isOwner) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.save), 
                  color: Colors.white,
                  tooltip: "บันทึกโปรไฟล์นี้",
                  style: IconButton.styleFrom(backgroundColor: Colors.white24),
                  onPressed: _saveAnalysisProfile,
                ),
                if (_currentAnalysisId != null) 
                  IconButton(
                    icon: const Icon(Icons.delete), 
                    color: Colors.red[200],
                    tooltip: "ลบโปรไฟล์นี้",
                    style: IconButton.styleFrom(backgroundColor: Colors.white24),
                    onPressed: _deleteAnalysisProfile,
                  )
              ]
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNPKField(String label, TextEditingController ctrl, Color fillColor) {
    return Expanded(
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        decoration: InputDecoration(labelText: label, labelStyle: const TextStyle(fontSize: 11), filled: true, fillColor: fillColor, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8)),
      ),
    );
  }

  Widget _buildAvgCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 4), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart, color: Colors.teal, size: 20), const SizedBox(width: 6),
              const Expanded(child: Text("ค่าเฉลี่ยทั้งแปลง", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.teal))),
              
              // ✅ ส่งข้อความแชทสรุปของ AI ไปที่ปุ่ม PDF ด้วย
              Builder(builder: (btnCtx) => IconButton(
                icon: const Icon(Icons.more_vert, color: Colors.teal, size: 22), 
                tooltip: "กราฟและรายงาน", 
                onPressed: () {
                  // รวบรวมข้อความแชตจาก AI (ถ้ามี)
                  String aiSummary = _chatMessages
                      .where((m) => !m.isUser && !m.isError && !m.isLoading)
                      .map((m) => m.text)
                      .join('\n\n');
                      
                  if (aiSummary.trim().isEmpty) {
                    aiSummary = "ยังไม่มีการดึงข้อมูลวิเคราะห์อัตโนมัติจากนักวิชาการ AI ในรอบนี้";
                  }

                  showChartMenu(
                    context: btnCtx, 
                    points: _points.asMap().entries.map((e) => ChartPointData(index: e.key, n: e.value.n, p: e.value.p, k: e.value.k, moisture: e.value.moisture, timestamp: e.value.timestamp?.toDate())).toList(), 
                    expectedN: _expectedN, 
                    expectedP: _expectedP, 
                    expectedK: _expectedK, 
                    tolerance: _tolerance, 
                    fertilizerAdvices: _getFertilizerAdvices().map((a) => "${a.nutrient}: ${a.dosageHint}").toList(), 
                    avgN: _avgN, 
                    avgP: _avgP, 
                    avgK: _avgK,
                    aiAnalysisText: aiSummary, // ✅ ส่ง parameter ที่เพิ่งเพิ่มเข้าไป
                  );
                }
              )),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildAvgBox("N", _avgN, _expectedN.toDouble(), Colors.blue),
              _buildAvgBox("P", _avgP, _expectedP.toDouble(), Colors.green[700]!),
              _buildAvgBox("K", _avgK, _expectedK.toDouble(), Colors.orange[800]!),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvgBox(String label, double avg, double expected, Color color) {
    double ratio = expected > 0 ? avg / expected : 1.0;
    double tLow = 1.0 - (_tolerance / 100);
    double tHigh = 1.0 + (_tolerance / 100);
    bool inRange = ratio >= tLow && ratio <= tHigh;
    Color statusColor = expected == 0 ? Colors.grey : inRange ? Colors.green : (ratio < tLow ? Colors.red : Colors.orange);

    return Column(
      children: [
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.4))),
          child: Column(
            children: [
              Text(avg.toStringAsFixed(1), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
              Text("mg/kg", style: TextStyle(fontSize: 10, color: Colors.grey[500])),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: statusColor.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                child: Text(expected == 0 ? "-" : inRange ? "✓ ปกติ" : ratio < tLow ? "▼ ต่ำ" : "▲ สูง", style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFertilizerSection() {
    final advices = _getFertilizerAdvices();
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [Icon(Icons.grass, color: Colors.green, size: 20), SizedBox(width: 6), Text("คำแนะนำปุ๋ยสำหรับแปลงนี้", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.green))]),
          const SizedBox(height: 4),
          Text("คำนวณจากค่าเฉลี่ย ${_points.length} จุดตรวจ เทียบกับค่าที่คาดหวัง ±${_tolerance.toInt()}%", style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          const SizedBox(height: 10),
          if (advices.isEmpty)
             Container(
               width: double.infinity, padding: const EdgeInsets.all(14), 
               decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.green[200]!)), 
               child: const Row(children: [Icon(Icons.check_circle, color: Colors.green, size: 22), SizedBox(width: 10), Expanded(child: Text("ค่าดิน N P K อยู่ในเกณฑ์ปกติทั้งหมด\nไม่จำเป็นต้องปรับปรุงในรอบนี้", style: TextStyle(color: Colors.green, fontWeight: FontWeight.w500, fontSize: 13)))])
             )
          else
            ...advices.map((a) => _buildAdviceCard(a)),
          const SizedBox(height: 6),
          Text("* ปริมาณปุ๋ยเป็นค่าประมาณเบื้องต้น ควรปรึกษานักวิชาการเกษตรก่อนใช้จริง", style: TextStyle(fontSize: 10, color: Colors.grey[400])),
        ],
      ),
    );
  }

  Widget _buildAdviceCard(_FertilizerAdvice a) {
    final bool isLow = a.status == _NutrientStatus.low;
    return Container(
      margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: a.color.withOpacity(0.05), borderRadius: BorderRadius.circular(10), border: Border.all(color: a.color.withOpacity(0.35))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isLow ? Icons.arrow_downward : Icons.arrow_upward, color: a.color, size: 16),
              const SizedBox(width: 6),
              Flexible(child: Text(a.nutrient, style: TextStyle(color: a.color, fontWeight: FontWeight.bold, fontSize: 14))),
              const SizedBox(width: 4),
              Flexible(child: Text("เฉลี่ย ${a.avgValue.toStringAsFixed(1)} / คาดหวัง ${a.expectedValue.toStringAsFixed(0)} mg/kg", style: TextStyle(fontSize: 11, color: Colors.grey[600]), textAlign: TextAlign.right, overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 8),
          if (isLow) ...[
            Wrap(
              children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: a.color.withOpacity(0.12), borderRadius: BorderRadius.circular(6)), child: Text(a.fertilizerName, style: TextStyle(color: a.color, fontWeight: FontWeight.bold, fontSize: 13))),
              ],
            ),
            const SizedBox(height: 6),
            Text(a.fertilizerDetail, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            const SizedBox(height: 4),
          ],
          Container(
            padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(6)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.grey[500]),
                const SizedBox(width: 6),
                Expanded(child: Text(a.dosageHint, style: TextStyle(fontSize: 12, color: Colors.grey[700]))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAISection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.deepPurple, size: 20),
                const SizedBox(width: 6),
                const Expanded(child: Text("ถามนักวิชาการเกษตร AI", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.deepPurple))),
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.deepPurple.withOpacity(0.1), borderRadius: BorderRadius.circular(6)), child: const Text("Gemini", style: TextStyle(fontSize: 10, color: Colors.deepPurple, fontWeight: FontWeight.bold))),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _startNewChat, 
                  icon: const Icon(Icons.refresh, size: 14), 
                  label: const Text("เริ่มใหม่", style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(foregroundColor: Colors.deepPurple, visualDensity: VisualDensity.compact),
                )
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isAiLoading ? null : _analyzeWithAI,
                icon: _isAiLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurple)) : const Icon(Icons.auto_awesome, size: 16),
                label: Text(_isAiLoading ? "AI กำลังวิเคราะห์..." : "วิเคราะห์ภาพรวมดินอัตโนมัติ"),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.deepPurple, side: const BorderSide(color: Colors.deepPurple), padding: const EdgeInsets.symmetric(vertical: 10)),
              ),
            ),
          ),
          if (_chatMessages.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              height: 280,
              margin: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey[200]!)),
              child: ListView.builder(
                controller: _chatScrollController,
                padding: const EdgeInsets.all(10),
                itemCount: _chatMessages.length + (_isAiLoading ? 1 : 0),
                itemBuilder: (ctx, i) {
                  if (i == _chatMessages.length && _isAiLoading) return _buildTypingIndicator();
                  return _buildChatBubble(_chatMessages[i]);
                },
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatInputController,
                    enabled: !_isAiLoading,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(hintText: "ถามเกี่ยวกับดิน เช่น ควรปลูกพืชอะไร?", hintStyle: TextStyle(fontSize: 13, color: Colors.grey[400]), filled: true, fillColor: Colors.grey[100], contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
                    onSubmitted: (v) => _sendChat(v),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _isAiLoading ? null : () => _sendChat(_chatInputController.text),
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: _isAiLoading ? Colors.grey[300] : Colors.deepPurple, shape: BoxShape.circle),
                    child: const Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text("* AI รับรู้ข้อมูลดินของแปลงนี้อัตโนมัติ — ถามได้เลยโดยไม่ต้องระบุค่าซ้ำ", style: TextStyle(fontSize: 10, color: Colors.grey[400])),
          ),
        ],
      ),
    );
  }

  Widget _buildChatBubble(_ChatMessage msg) {
    final bool isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(radius: 14, backgroundColor: Colors.deepPurple[100], child: const Icon(Icons.auto_awesome, size: 14, color: Colors.deepPurple)),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: isUser ? Colors.deepPurple : msg.isError ? Colors.red[50] : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14), 
                  topRight: const Radius.circular(14), 
                  bottomLeft: Radius.circular(isUser ? 14 : 4), 
                  bottomRight: Radius.circular(isUser ? 4 : 14)
                ),
                border: isUser ? null : Border.all(color: msg.isError ? Colors.red[200]! : Colors.grey[200]!),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 1))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. เปลี่ยนเป็น SelectableText เพื่อให้ลากคลุมดำเลือกก็อปปี้บางคำเองได้
                  SelectableText(
                    msg.text, 
                    style: TextStyle(
                      fontSize: 13, 
                      height: 1.5, 
                      color: isUser ? Colors.white : msg.isError ? Colors.red[700] : Colors.black87
                    ),
                  ),
                  // 2. ถ้าเป็นข้อความจาก AI และไม่ใช่ข้อความ Error ให้แสดงปุ่มลัดสำหรับกดก๊อปปี้ง่ายๆ
                  if (!isUser && !msg.isError) ...[
                    const Divider(height: 12, thickness: 0.5),
                    Align(
                      alignment: Alignment.centerRight,
                      child: InkWell(
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: msg.text));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("คัดลอกรายงานวิเคราะห์ดินเรียบร้อยแล้ว"),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy, size: 12, color: Colors.grey[500]),
                            const SizedBox(width: 4),
                            Text("คัดลอกทั้งหมด", style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                          ],
                        ),
                      ),
                    ),
                  ]
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(radius: 14, backgroundColor: Colors.deepPurple[100], child: const Icon(Icons.auto_awesome, size: 14, color: Colors.deepPurple)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.grey[200]!)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [_buildDot(0), const SizedBox(width: 4), _buildDot(1), const SizedBox(width: 4), _buildDot(2)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1.0), duration: Duration(milliseconds: 400 + index * 150),
      builder: (_, v, __) => Opacity(opacity: v, child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.deepPurple, shape: BoxShape.circle))),
    );
  }

  Widget _buildMap() {
    List<Marker> markers = [];
    for (int i = 0; i < _points.length; i++) {
      final p = _points[i];
      final status = _evaluatePoint(p);
      final color = _statusColor(status);
      markers.add(
        Marker(
          point: LatLng(p.lat, p.lng),
          width: 56, height: 56,
          child: GestureDetector(
            onTap: () => _showPointDetail(p, status),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(width: 48, height: 48, decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.25), border: Border.all(color: color, width: 3))),
                Text("${i + 1}", style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
          ),
        ),
      );
    }

    LatLng center = _points.isNotEmpty ? LatLng(_points.first.lat, _points.first.lng) : const LatLng(13.7563, 100.5018);

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(initialCenter: center, initialZoom: 16.0),
      children: [
        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.soil_app'),
        MarkerLayer(markers: markers),
      ],
    );
  }

  Widget _buildSummaryBar(Map<_PointStatus, int> summary) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildSummaryChip(_PointStatus.good, summary[_PointStatus.good] ?? 0),
          _buildSummaryChip(_PointStatus.warning, summary[_PointStatus.warning] ?? 0),
          _buildSummaryChip(_PointStatus.bad, summary[_PointStatus.bad] ?? 0),
          Text("รวม ${_points.length} จุด", style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildSummaryChip(_PointStatus status, int count) {
    return Row(
      children: [
        Icon(_statusIcon(status), color: _statusColor(status), size: 18),
        const SizedBox(width: 4),
        Text("$count จุด", style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    );
  }

  Widget _buildPointList() {
    return ListView.builder(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      itemCount: _points.length,
      itemBuilder: (ctx, i) {
        final p = _points[i];
        final status = _evaluatePoint(p);
        final color = _statusColor(status);
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: color.withOpacity(0.5), width: 1.5)),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: color.withOpacity(0.15), child: Text("${i + 1}", style: TextStyle(color: color, fontWeight: FontWeight.bold))),
            title: Row(
              children: [
                Icon(_statusIcon(status), color: color, size: 16), const SizedBox(width: 4),
                Text(_statusLabel(status), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(_formatDateTime(p.timestamp), style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  _buildMiniNPK("N", p.n, _expectedN, Colors.blue), const SizedBox(width: 8),
                  _buildMiniNPK("P", p.p, _expectedP, Colors.green[700]!), const SizedBox(width: 8),
                  _buildMiniNPK("K", p.k, _expectedK, Colors.orange[800]!), const Spacer(),
                  Icon(Icons.water_drop, size: 13, color: Colors.blue[300]),
                  Text(" ${p.moisture}%", style: TextStyle(fontSize: 12, color: Colors.blue[400])),
                ],
              ),
            ),
            onTap: () => _showPointDetail(p, status),
          ),
        );
      },
    );
  }

  Widget _buildMiniNPK(String label, int value, int expected, Color color) {
    String diff = expected > 0 ? (value >= expected ? "+${value - expected}" : "${value - expected}") : "";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("$value", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: color)),
            if (diff.isNotEmpty) Text(" ($diff)", style: TextStyle(fontSize: 10, color: diff.startsWith('+') ? Colors.green : Colors.red)),
          ],
        ),
      ],
    );
  }

  void _showPointDetail(_PointData p, _PointStatus status) {
    final color = _statusColor(status);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_statusIcon(status), color: color, size: 26), const SizedBox(width: 10),
                  Flexible(child: Text("สถานะ: ${_statusLabel(status)}", style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold))),
                ],
              ),
              const SizedBox(height: 4),
              Text(_formatDateTime(p.timestamp), style: const TextStyle(fontSize: 13, color: Colors.grey)),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildDetailBox("N", p.n, _expectedN, Colors.blue),
                  _buildDetailBox("P", p.p, _expectedP, Colors.green[700]!),
                  _buildDetailBox("K", p.k, _expectedK, Colors.orange[800]!),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.water_drop, color: Colors.blue, size: 20), const SizedBox(width: 6),
                  Text("ความชื้น: ${p.moisture}%", style: const TextStyle(fontSize: 16)),
                ],
              ),
              const SizedBox(height: 8),
              Center(child: Text("พิกัด: ${p.lat.toStringAsFixed(6)}, ${p.lng.toStringAsFixed(6)}", style: const TextStyle(fontSize: 11, color: Colors.grey))),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailBox(String label, int value, int expected, Color color) {
    double ratio = expected > 0 ? value / expected : 1.0;
    String ratioStr = expected > 0 ? "${(ratio * 100).toStringAsFixed(0)}%" : "-";
    return Column(
      children: [
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: color, width: 1.5)),
          child: Column(
            children: [
              Text("$value", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
              Text("คาดหวัง: $expected", style: const TextStyle(fontSize: 11, color: Colors.grey)),
              Text(ratioStr, style: TextStyle(fontSize: 12, color: ratio >= 0.8 && ratio <= 1.2 ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }
}

// ==========================================
// 📦 Models
// ==========================================
enum _PointStatus { good, warning, bad, neutral }
enum _NutrientStatus { low, high }

class _ChatMessage {
  final String text;
  final bool isUser;
  final bool isError;
  final bool isLoading;

  _ChatMessage({required this.text, required this.isUser, this.isError = false, this.isLoading = false});

  Map<String, dynamic> toMap() => {'text': text, 'isUser': isUser};
  factory _ChatMessage.fromMap(Map<String, dynamic> map) => _ChatMessage(text: map['text'] ?? '', isUser: map['isUser'] ?? false);
}

class _PointData {
  final String id; final double lat; final double lng; final int n; final int p; final int k; final int moisture; final Timestamp? timestamp; final String source;
  _PointData({required this.id, required this.lat, required this.lng, required this.n, required this.p, required this.k, required this.moisture, required this.timestamp, required this.source});
}

class _FertilizerAdvice {
  final String nutrient; final _NutrientStatus status; final double avgValue; final double expectedValue; final String fertilizerName; final String fertilizerDetail; final String dosageHint; final Color color;
  _FertilizerAdvice({required this.nutrient, required this.status, required this.avgValue, required this.expectedValue, required this.fertilizerName, required this.fertilizerDetail, required this.dosageHint, required this.color});
}