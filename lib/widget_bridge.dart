import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart' show Stroke;
import 'theme.dart' show adaptiveInkFor;

// ---------------------------------------------------------------------------
//  Widżety ekranu głównego (Android): most Dart <-> AppWidgetProvider.
//
//  Trzy widżety (Kotlin, android/app/src/main/kotlin/...):
//   - TinCanChatsWidgetProvider        — pasek skrótów do czatów (ikonki osób),
//   - TinCanDrawingWidgetProvider      — ostatni rysunek OD osoby (kwadrat),
//   - TinCanDrawingWidgetTallProvider  — jak wyżej, pionowy prostokąt.
//
//  Dane wymieniamy przez SharedPreferences home_widget:
//   - widget_people           JSON [{id,label}] — osoby, dla których renderujemy,
//   - widget_img_<id>         ścieżka PNG z ostatnim rysunkiem od osoby,
//   - widget_caption_<id>     podpis („od @x · 14:32”),
//   - pending_widget_person   JSON {id,label} — konfiguracja czekająca na
//                             przypięcie nowej instancji (przejmie ją provider),
//   - widget_person_<widgetId> (zapisuje Kotlin) — mapowanie instancja->osoba,
//   - chats_widget            JSON [{id,label,initial}] — sloty paska czatów.
//
//  Klik w widżet niesie uri: tincan://chat/<peerId>?label=<...> — apka
//  otwiera wtedy bezpośrednio ekran rysowania z tą osobą (main.dart).
// ---------------------------------------------------------------------------

bool get isAndroidApp => !kIsWeb && Platform.isAndroid;

const _qualifiedSquare = 'com.example.tin_can.TinCanDrawingWidgetProvider';
const _qualifiedTall = 'com.example.tin_can.TinCanDrawingWidgetTallProvider';
const _qualifiedChats = 'com.example.tin_can.TinCanChatsWidgetProvider';

String _fmtTime(DateTime t) {
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  final hh =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (sameDay) return hh;
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} $hh';
}

// --- Render: kreski -> PNG (tło = kolor płótna z apki, gumka wycina). ---
Future<Uint8List?> _renderStrokesPng(
    List<Stroke> strokes, Color canvasColor) async {
  if (strokes.isEmpty) return null;
  double minX = double.infinity, minY = double.infinity;
  double maxX = -double.infinity, maxY = -double.infinity;
  for (final s in strokes) {
    for (final p in s.points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
  }
  if (minX > maxX || minY > maxY) return null;

  const maxSide = 640.0, pad = 28.0;
  final w = math.max(maxX - minX, 1.0);
  final h = math.max(maxY - minY, 1.0);
  final aspect = w / h;
  final outW = aspect >= 1 ? maxSide : (maxSide * aspect).clamp(280.0, maxSide);
  final outH = aspect >= 1 ? (maxSide / aspect).clamp(280.0, maxSide) : maxSide;
  final scale = math.min((outW - 2 * pad) / w, (outH - 2 * pad) / h);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, outW, outH);
  canvas.drawRect(rect, Paint()..color = canvasColor);

  // Warstwa na tusz — gumka (BlendMode.clear) odsłania kolor płótna, jak w apce.
  canvas.saveLayer(rect, Paint());
  canvas.translate(
    (outW - w * scale) / 2 - minX * scale,
    (outH - h * scale) / 2 - minY * scale,
  );
  canvas.scale(scale);
  for (final stroke in strokes) {
    if (stroke.points.length < 2) continue;
    final paint = Paint()
      ..color = stroke.adaptive ? adaptiveInkFor(canvasColor) : stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;
    final path = Path()
      ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (final p in stroke.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }
  canvas.restore();

  final img =
      await recorder.endRecording().toImage(outW.round(), outH.round());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}

// --- Lista osób, dla których utrzymujemy obraz rysunku. ---
Future<List<Map<String, String>>> _widgetPeople() async {
  final raw = await HomeWidget.getWidgetData<String>('widget_people');
  if (raw == null || raw.isEmpty) return [];
  try {
    return (jsonDecode(raw) as List)
        .map((e) => {
              'id': (e['id'] ?? '') as String,
              'label': (e['label'] ?? '') as String,
            })
        .where((e) => e['id']!.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> _savePeople(List<Map<String, String>> people) async {
  await HomeWidget.saveWidgetData<String>('widget_people', jsonEncode(people));
}

// Renderuje i zapisuje ostatni rysunek OD danej osoby (sender=peer, do mnie).
Future<void> _refreshPerson(
  SupabaseClient supabase,
  String myId,
  String peerId,
  String label,
  Color canvasColor,
) async {
  final rows = await supabase
      .from('drawings')
      .select()
      .eq('recipient', myId)
      .eq('sender', peerId)
      .order('created_at', ascending: false)
      .limit(1);
  final list = rows as List;
  if (list.isEmpty) {
    await HomeWidget.saveWidgetData<String>(
        'widget_caption_$peerId', '$label · jeszcze nic tu nie ma');
    return;
  }
  final row = list.first as Map<String, dynamic>;
  final strokes = (row['strokes'] as List)
      .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
      .toList();
  final png = await _renderStrokesPng(strokes, canvasColor);
  if (png == null) return;
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}/widget_$peerId.png');
  await file.writeAsBytes(png, flush: true);
  final at =
      DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now();
  await HomeWidget.saveWidgetData<String>('widget_img_$peerId', file.path);
  await HomeWidget.saveWidgetData<String>(
      'widget_caption_$peerId', 'od $label · ${_fmtTime(at)}');
}

// Prosi providery o przerysowanie.
Future<void> _pushUpdate() async {
  await HomeWidget.updateWidget(qualifiedAndroidName: _qualifiedSquare);
  await HomeWidget.updateWidget(qualifiedAndroidName: _qualifiedTall);
  await HomeWidget.updateWidget(qualifiedAndroidName: _qualifiedChats);
}

// Zapisuje motyw widżetów dla warstwy Kotlin: kolor płótna (ten sam co w czacie
// rysunkowym) i czy apka jest w trybie ciemnym. Zwraca kolor płótna do renderu.
Future<Color> _saveWidgetTheme() async {
  var canvasColor = const Color(0xFFFBF8F1);
  var dark = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    dark = prefs.getBool('dark_mode') ?? false;
    final v = prefs.getInt('canvas_color');
    // Brak ręcznego wyboru = AUTO: papier na jasnym, noc na ciemnym —
    // dokładnie jak płótno w czacie rysunkowym.
    canvasColor = v != null
        ? Color(v)
        : (dark ? const Color(0xFF14101F) : const Color(0xFFFBF8F1));
  } catch (_) {}
  // Kolor jako #RRGGBB (String) — bezpieczne dla Color.parseColor po stronie
  // Android (int przez home_widget bywa Long → wyjątek przy getInt).
  final rgb = canvasColor.toARGB32() & 0xFFFFFF;
  await HomeWidget.saveWidgetData<String>(
      'widget_canvas', '#${rgb.toRadixString(16).padLeft(6, '0')}');
  await HomeWidget.saveWidgetData<bool>('widget_dark', dark);
  return canvasColor;
}

/// Odśwież obrazy wszystkich skonfigurowanych widżetów rysunku.
/// Wołane: po wejściu do apki, po odebraniu rysunku, z handlera push w tle.
Future<void> refreshDrawingWidgets() async {
  if (!isAndroidApp) return;
  try {
    final canvasColor = await _saveWidgetTheme();
    final supabase = Supabase.instance.client;
    final me = supabase.auth.currentUser?.id;
    if (me == null) return;
    final people = await _widgetPeople();
    for (final p in people) {
      await _refreshPerson(supabase, me, p['id']!, p['label']!, canvasColor);
    }
    await _pushUpdate();
  } catch (e) {
    debugPrint('TINCAN_WIDGET_REFRESH_ERROR: $e');
  }
}

/// Konfiguruje NOWĄ instancję widżetu rysunku dla osoby i prosi launcher
/// o przypięcie. `tall` = wariant pionowy. Provider przejmie konfigurację
/// (pending) przy pierwszym odświeżeniu instancji.
Future<void> pinDrawingWidget({
  required String peerId,
  required String label,
  required bool tall,
}) async {
  if (!isAndroidApp) return;
  try {
    // dopisz osobę do listy renderowanych
    final people = await _widgetPeople();
    if (!people.any((p) => p['id'] == peerId)) {
      people.add({'id': peerId, 'label': label});
      await _savePeople(people);
    }
    await HomeWidget.saveWidgetData<String>(
        'pending_widget_person', jsonEncode({'id': peerId, 'label': label}));
    await refreshDrawingWidgets(); // obraz gotowy zanim widżet się pojawi
    await HomeWidget.requestPinWidget(
      qualifiedAndroidName: tall ? _qualifiedTall : _qualifiedSquare,
    );
  } catch (e) {
    debugPrint('TINCAN_WIDGET_PIN_ERROR: $e');
  }
}

/// Zapisuje osoby paska „szybkie czaty” (max 5) i prosi o przypięcie.
Future<void> pinChatsWidget(List<Map<String, String>> people) async {
  if (!isAndroidApp) return;
  try {
    await _saveWidgetTheme(); // pasek czatów też ma iść w parze z motywem apki
    final slots = people
        .take(5)
        .map((p) => {
              'id': p['id'],
              'label': p['label'],
              'initial': (p['label'] ?? '?')
                  .replaceAll('@', '')
                  .trim()
                  .padRight(1)
                  .substring(0, 1)
                  .toUpperCase(),
            })
        .toList();
    await HomeWidget.saveWidgetData<String>('chats_widget', jsonEncode(slots));
    await HomeWidget.updateWidget(qualifiedAndroidName: _qualifiedChats);
    await HomeWidget.requestPinWidget(qualifiedAndroidName: _qualifiedChats);
  } catch (e) {
    debugPrint('TINCAN_WIDGET_CHATS_ERROR: $e');
  }
}
