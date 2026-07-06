import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_gate.dart';
import 'chime.dart';
import 'logo.dart';
import 'push.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://safvbfwtqjlgcegnyckp.supabase.co',
    publishableKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNhZnZiZnd0cWpsZ2NlZ255Y2twIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI2NTg3NjAsImV4cCI6MjA5ODIzNDc2MH0.06giB9KYiw9BI1Q0FYijhn3-QO5PdcV9pZ0mi8ejS00',
  );
  await initFirebaseIfMobile();
  runApp(const TinCanApp());
}

class TinCanApp extends StatelessWidget {
  const TinCanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tin Can',
      debugShowCheckedModeBanner: false,
      theme: buildTinCanTheme(),
      home: const AuthGate(),
    );
  }
}

// Jedna kreska = kolor, grubość i lista punktów (w pikselach na razie).
class Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser; // gumka: wycinamy tusz (BlendMode.clear), nie malujemy

  Stroke({
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
  });

  // Kreska -> JSON do bazy. Kolor jako RRGGBB (hex), punkty spłaszczone [dx,dy,dx,dy,...].
  Map<String, dynamic> toJson() {
    final r = (color.r * 255).round();
    final g = (color.g * 255).round();
    final b = (color.b * 255).round();
    final hex = ((r << 16) | (g << 8) | b).toRadixString(16).padLeft(6, '0');
    return {
      'color': hex,
      'width': width,
      'points': points.expand((p) => [p.dx, p.dy]).toList(),
    };
  }

  // JSON z bazy -> kreska. Odwrotność toJson(): odbudowujemy punkty parami.
  factory Stroke.fromJson(Map<String, dynamic> json) {
    final flat = (json['points'] as List).cast<num>();
    final pts = <Offset>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      pts.add(Offset(flat[i].toDouble(), flat[i + 1].toDouble()));
    }
    final rgb = int.parse(json['color'] as String, radix: 16);
    return Stroke(
      points: pts,
      color: Color.fromARGB(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF),
      width: (json['width'] as num).toDouble(),
    );
  }

  int get pointCount => points.length;
}

// Jeden rysunek w historii — wysłany albo odebrany.
class ReceivedDrawing {
  final String sender;
  final String recipient;
  final bool outgoing; // true = ja wysłałem; false = przyszło do mnie
  final String other; // druga strona (do kogo / od kogo)
  final DateTime createdAt;
  final List<Stroke> strokes;

  ReceivedDrawing({
    required this.sender,
    required this.recipient,
    required this.outgoing,
    required this.other,
    required this.createdAt,
    required this.strokes,
  });

  // Buduje z wiersza bazy / payloadu realtime; myId ustala kierunek (od/do).
  factory ReceivedDrawing.fromRow(Map<String, dynamic> row, String myId) {
    final sender = (row['sender'] as String?) ?? '?';
    final recipient = (row['recipient'] as String?) ?? '?';
    final outgoing = sender == myId;
    final strokes = (row['strokes'] as List)
        .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
        .toList();
    return ReceivedDrawing(
      sender: sender,
      recipient: recipient,
      outgoing: outgoing,
      other: outgoing ? recipient : sender,
      createdAt:
          DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
      strokes: strokes,
    );
  }
}

class DrawingScreen extends StatefulWidget {
  final String? peerId; // 1:1: user_id drugiej osoby
  final String? groupId; // grupa: id grupy (wtedy peerId == null)
  final String peerLabel; // etykieta w pasku (osoba albo nazwa grupy)

  const DrawingScreen({
    super.key,
    this.peerId,
    this.groupId,
    required this.peerLabel,
  });

  bool get isGroup => groupId != null;

  @override
  State<DrawingScreen> createState() => _DrawingScreenState();
}

class _DrawingScreenState extends State<DrawingScreen>
    with SingleTickerProviderStateMixin {
  // Połączenie z bazą.
  final supabase = Supabase.instance.client;

  // Tożsamości wątku: ja = zalogowane konto, peer = druga osoba z puszki.
  late final String myId;
  String? get peerId => widget.peerId;

  // Wszystkie ukończone kreski.
  final List<Stroke> _strokes = [];
  // Kreska, którą właśnie rysujemy (palec/mysz wciśnięty).
  Stroke? _currentStroke;

  // Wybór pędzla.
  Color _brushColor = Colors.black;
  double _brushWidth = 4.0;
  bool _eraser = false;

  // Ile sekund ma trwać odrysowywanie (materializacja) odebranej wiadomości.
  // Ustawia ODBIORCA suwakiem — duże rysunki nie muszą już przelatywać w sekundę.
  double _redrawSeconds = 3.0;

  // Historia odebranych rysunków (najnowsze pierwsze): z bazy na starcie + realtime.
  final List<ReceivedDrawing> _history = [];
  bool _historyLoading = true;

  // #4: gdy mam na płótnie swój NIEWYSŁANY rysunek, przychodzący go nie kasuje —
  // czeka jako "pending" za banerem (pokaże się po wysłaniu albo po dotknięciu).
  bool _drawingMine = false;
  // #4: MÓJ rysunek odłożony "do kieszeni", gdy przyszedł cudzy w trakcie rysowania.
  List<Stroke>? _stashedMine;

  // Nasłuch realtime na rysunki przychodzące do nas.
  RealtimeChannel? _channel;
  // Animacja "materializacji" — odebrany rysunek odtwarza się kreska po kresce.
  late final AnimationController _revealController;
  // Czy właśnie odtwarzamy przychodzący rysunek (wtedy odsłaniamy stopniowo).
  bool _materializing = false;

  // Ułamek punktów do pokazania: w trakcie materializacji rośnie 0->1,
  // poza nią zawsze 1.0 (własne kreski widać natychmiast).
  double get _reveal => _materializing ? _revealController.value : 1.0;

  // Kratka pomocnicza na płótnie: pokazuj, gdy rysuję swoje albo płótno jest
  // puste; chowaj, gdy pojawia się rysunek OD kogoś (materializacja/odebrany) —
  // wtedy rysunek „ląduje" na czystej kartce.
  bool get _showGrid =>
      _drawingMine ||
      (_strokes.isEmpty && _currentStroke == null && !_materializing);

  @override
  void initState() {
    super.initState();
    myId = supabase.auth.currentUser!.id;

    _revealController = AnimationController(vsync: this, value: 1.0)
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _materializing = false);
        }
      });

    _subscribe();
    _loadHistory();
  }

  // Subskrybujemy INSERT-y do tabeli drawings, gdzie recipient == my.
  // Gdy coś wpadnie, drugi koniec "zapala się sam" — bez pollingu.
  void _subscribe() {
    _channel = supabase
        .channel('drawings:$myId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'drawings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient',
            value: myId,
          ),
          callback: _onIncoming,
        )
        .subscribe((status, [error]) {
          debugPrint('TINCAN_SUB: $status ${error ?? ''}');
        });
  }

  // Wczytanie historii odebranych rysunków z bazy (najnowsze pierwsze).
  Future<void> _loadHistory() async {
    try {
      final base = supabase
          .from('drawings')
          .select('sender, recipient, created_at, strokes');
      final rows = widget.isGroup
          ? await base
              .eq('group_id', widget.groupId!)
              .eq('recipient', myId)
              .order('created_at', ascending: false)
              .limit(50)
          : await base
              .or('and(sender.eq.$myId,recipient.eq.${widget.peerId}),'
                  'and(sender.eq.${widget.peerId},recipient.eq.$myId)')
              .order('created_at', ascending: false)
              .limit(50);
      final items = (rows as List)
          .map((r) => ReceivedDrawing.fromRow(r as Map<String, dynamic>, myId))
          .toList();
      if (mounted) {
        setState(() {
          _history
            ..clear()
            ..addAll(items);
          // #5: jeśli ostatni rysunek w wątku jest OD peera — pokaż go od razu
          // na płótnie (nie tylko w historii). Bez animacji (to nie "na żywo").
          if (items.isNotEmpty && !items.first.outgoing) {
            _strokes
              ..clear()
              ..addAll(items.first.strokes);
            _drawingMine = false;
          }
        });
      }
    } catch (e) {
      debugPrint('TINCAN_HISTORY_ERROR: $e');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  void _onIncoming(PostgresChangePayload payload) {
    final rec = payload.newRecord;
    if (widget.isGroup) {
      // grupa: rysunki tej grupy, ale nie własne echo (self-kopia)
      if (rec['group_id'] != widget.groupId || rec['sender'] == myId) return;
    } else {
      // 1:1: tylko od peera i tylko nie-grupowe
      if (rec['group_id'] != null || rec['sender'] != widget.peerId) return;
    }
    final received = ReceivedDrawing.fromRow(
      Map<String, dynamic>.from(payload.newRecord),
      myId,
    );
    debugPrint('TINCAN_RX: odebrano ${received.strokes.length} kresek od ${received.sender}');

    setState(() => _history.insert(0, received));

    // #4: jeśli rysuję właśnie swoje (niewysłane) — odłóż je do kieszeni,
    // pokaż normalnie przychodzący rysunek, a MÓJ da się przywrócić ikoną.
    if (_drawingMine && _strokes.isNotEmpty) {
      _stashedMine = List<Stroke>.from(_strokes);
    }
    _materialize(received.strokes);

    // Miły "ding" — sygnał, że coś przyszło (Web Audio na web; na mobile cisza).
    playChime();
  }

  // Wrzuca dany rysunek na płótno i odpala animację materializacji.
  void _materialize(List<Stroke> strokes) {
    setState(() {
      _strokes
        ..clear()
        ..addAll(strokes);
      _currentStroke = null;
      _materializing = true;
      _drawingMine = false; // płótno pokazuje teraz cudzy rysunek
    });
    // Czas odrysowywania ustawia odbiorca (suwak ⏱ w pasku u góry).
    _revealController
      ..duration = Duration(milliseconds: (_redrawSeconds * 1000).round())
      ..forward(from: 0.0);
  }

  // #4: przywróć MÓJ rysunek, który był w toku, gdy przyszedł cudzy.
  void _restoreMine() {
    final mine = _stashedMine;
    if (mine == null) return;
    _materializing = false;
    _revealController.stop();
    setState(() {
      _strokes
        ..clear()
        ..addAll(mine);
      _currentStroke = null;
      _drawingMine = true;
      _stashedMine = null;
    });
  }

  @override
  void dispose() {
    _revealController.dispose();
    final channel = _channel;
    if (channel != null) supabase.removeChannel(channel);
    super.dispose();
  }

  void _startStroke(Offset position) {
    // Gdy zaczynamy rysować, przerywamy ewentualną materializację —
    // własne kreski mają być widoczne od razu, w pełni.
    _materializing = false;
    _revealController.stop();
    setState(() {
      // #5: jeśli na płótnie był cudzy (odebrany) rysunek — zaczynamy na czysto.
      if (!_drawingMine) _strokes.clear();
      _drawingMine = true; // to jest mój rysunek — chroń go przed nadpisaniem
      _currentStroke = Stroke(
        points: [position],
        // Gumka wycina tusz (patrz DrawingPainter) — kolor bez znaczenia dla
        // renderu, ale zostaje biały dla zapisu i podglądu u odbiorcy.
        color: _eraser ? Colors.white : _brushColor,
        width: _eraser ? 18.0 : _brushWidth,
        isEraser: _eraser,
      );
    });
  }

  void _addPoint(Offset position) {
    setState(() {
      _currentStroke?.points.add(position);
    });
  }

  void _endStroke() {
    setState(() {
      if (_currentStroke != null) {
        _strokes.add(_currentStroke!);
        _currentStroke = null;
      }
    });
  }

  void _clear() {
    _materializing = false;
    _revealController.stop();
    setState(() {
      _strokes.clear();
      _currentStroke = null;
      _drawingMine = false;
      _stashedMine = null;
    });
  }

  // Wysyłka: kreski -> JSON -> tabela drawings. Po wysłaniu czyścimy płótno.
  Future<void> _send() async {
    if (_strokes.isEmpty) return;
    final snapshot = List<Stroke>.from(_strokes);
    final strokesJson = snapshot.map((s) => s.toJson()).toList();
    try {
      if (widget.isGroup) {
        await supabase.rpc('send_group_drawing', params: {
          'p_group_id': widget.groupId,
          'p_strokes': strokesJson,
        });
      } else {
        await supabase.from('drawings').insert({
          'sender': myId,
          'recipient': widget.peerId,
          'strokes': strokesJson,
        });
      }
      // Do lokalnej historii (natychmiastowy podgląd; reload i tak dociągnie).
      setState(() {
        _history.insert(
          0,
          ReceivedDrawing(
            sender: myId,
            recipient: widget.peerId ?? myId,
            outgoing: true,
            other: widget.peerId ?? '',
            createdAt: DateTime.now(),
            strokes: snapshot,
          ),
        );
      });
      _clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wysłano! 🪂')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd: $e')),
        );
      }
    }
  }

  // Suwak: ile czasu ma trwać odrysowywanie odebranej wiadomości.
  void _openSpeedSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Czas odrysowywania wiadomości',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Jak długo ma „rysować się" rysunek, który do Ciebie przyleci.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    Row(
                      children: [
                        const Icon(Icons.bolt, size: 20),
                        Expanded(
                          child: Slider(
                            min: 0.5,
                            max: 15.0,
                            divisions: 29,
                            value: _redrawSeconds,
                            label: '${_redrawSeconds.toStringAsFixed(1)} s',
                            onChanged: (v) {
                              setSheet(() {});
                              setState(() => _redrawSeconds = v);
                            },
                          ),
                        ),
                        const Icon(Icons.hourglass_bottom, size: 20),
                      ],
                    ),
                    Center(
                      child: Text('${_redrawSeconds.toStringAsFixed(1)} s',
                          style: Theme.of(ctx).textTheme.titleLarge),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Galeria odebranych rysunków — klik miniatury odtwarza ją na płótnie.
  Future<void> _openGallery() async {
    final picked = await Navigator.of(context).push<ReceivedDrawing>(
      MaterialPageRoute(
        builder: (_) => GalleryScreen(
          history: _history,
          loading: _historyLoading,
        ),
      ),
    );
    if (picked != null) {
      _revealController.stop();
      _materialize(picked.strokes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TinCanLogo(width: 26),
            const SizedBox(width: 10),
            Flexible(
              child: Text(widget.peerLabel, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _history.isNotEmpty,
              label: Text('${_history.length}'),
              child: const Icon(Icons.collections_outlined),
            ),
            onPressed: _openGallery,
            tooltip: 'Historia',
          ),
          IconButton(
            icon: const Icon(Icons.timer_outlined),
            onPressed: _openSpeedSheet,
            tooltip: 'Czas odrysowywania',
          ),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _send,
            tooltip: 'Wyślij',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
            tooltip: 'Wyczyść',
          ),
        ],
        // Cienki pasek postępu — wypełnia się, gdy rysunek się materializuje.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _materializing
              ? LinearProgressIndicator(value: _reveal, minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      bottomNavigationBar: _buildToolbar(),
      body: Stack(
        children: [
          GestureDetector(
            onPanStart: (details) => _startStroke(details.localPosition),
            onPanUpdate: (details) => _addPoint(details.localPosition),
            onPanEnd: (details) => _endStroke(),
            child: Container(
              color: Colors.white,
              width: double.infinity,
              height: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Kratka pomocnicza — płynnie znika, gdy nadchodzi rysunek.
                  AnimatedOpacity(
                    opacity: _showGrid ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    child: CustomPaint(painter: _CanvasGridPainter()),
                  ),
                  CustomPaint(
                    painter: DrawingPainter(
                      strokes: _strokes,
                      currentStroke: _currentStroke,
                      reveal: _reveal,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // #4: cudzy rysunek pokazał się normalnie, a Twój był w toku —
          // ta ikona przywraca Twój rysunek.
          if (_stashedMine != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Center(
                child: Material(
                  color: TC.brand,
                  borderRadius: BorderRadius.circular(24),
                  elevation: 3,
                  shadowColor: TC.brand.withValues(alpha: 0.5),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _restoreMine,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.undo, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text('Przywróć swój rysunek',
                              style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Pigułka "coś przyszło" — widoczna podczas materializacji.
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _materializing ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: TC.ink.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '✍️ ${widget.peerLabel} rysuje dla Ciebie…',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Pasek narzędzi (pędzel) ---

  static const List<Color> _palette = [
    Colors.black,
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF8E24AA),
    Color(0xFFEC407A),
  ];
  static const List<double> _brushWidths = [2.0, 6.0, 12.0];

  Widget _buildToolbar() {
    return Container(
      decoration: BoxDecoration(
        // Kremowy papier — wyraźnie odcina pasek od białego płótna.
        color: TC.paper2,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: TC.ink.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, -4),
            spreadRadius: -2,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final c in _palette) _colorSwatch(c),
                Container(
                  width: 1,
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: TC.ink.withValues(alpha: 0.14),
                ),
                for (final w in _brushWidths) _widthDot(w),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => setState(() => _eraser = !_eraser),
                  icon: const Icon(Icons.auto_fix_high),
                  tooltip: 'Gumka',
                  style: IconButton.styleFrom(
                    backgroundColor:
                        _eraser ? TC.brand.withValues(alpha: 0.15) : null,
                    foregroundColor: _eraser ? TC.brand : TC.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(Color c) {
    final selected = !_eraser && _brushColor == c;
    return GestureDetector(
      onTap: () => setState(() {
        _brushColor = c;
        _eraser = false;
      }),
      child: Container(
        width: 30,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? TC.brand : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  Widget _widthDot(double w) {
    final selected = !_eraser && _brushWidth == w;
    return GestureDetector(
      onTap: () => setState(() {
        _brushWidth = w;
        _eraser = false;
      }),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? TC.brand : Colors.transparent,
            width: 2,
          ),
        ),
        child: Center(
          child: Container(
            width: w + 8,
            height: w + 8,
            decoration: const BoxDecoration(
              color: TC.ink,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  // Ułamek 0..1 — ile punktów (w kolejności rysowania, przez wszystkie kreski)
  // odsłonić. 1.0 = cały rysunek. Używane do "materializacji" odebranego rysunku.
  final double reveal;

  DrawingPainter({
    required this.strokes,
    required this.currentStroke,
    this.reveal = 1.0,
  });

  // Rysuje kreskę tylko do `count` pierwszych punktów (count >= length = cała).
  void _drawStroke(Canvas canvas, Stroke stroke, int count) {
    final n = count.clamp(0, stroke.points.length);
    if (n < 2) return;

    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      // Gumka wycina tusz z warstwy (odsłania kratkę/papier pod spodem),
      // zamiast malować biel na wierzchu.
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;

    final path = Path()
      ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Ile punktów łącznie odsłonić (przez wszystkie ukończone kreski po kolei).
    final total = strokes.fold<int>(0, (sum, s) => sum + s.points.length);
    var target = (reveal.clamp(0.0, 1.0) * total).round();

    // Osobna warstwa na tusz: dzięki niej gumka (BlendMode.clear) wycina TYLKO
    // tusz, a kratka/papier pod spodem (rysowane niżej) zostają nietknięte.
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in strokes) {
      if (target <= 0) break;
      _drawStroke(canvas, stroke, target);
      target -= stroke.points.length;
    }

    // Kreskę rysowaną właśnie przez użytkownika pokazujemy zawsze w całości.
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!, currentStroke!.points.length);
    }
    canvas.restore();
  }

  @override
  // Zawsze przerysowuj: kreska w trakcie rysowania jest modyfikowana w miejscu
  // (ta sama referencja), więc porównywanie referencji gubiłoby punkty dorysowane
  // podczas przeciągania myszką. Repaint i tak odpala się tylko przy setState
  // (ruch myszką) albo klatce animacji materializacji — jest tani.
  bool shouldRepaint(DrawingPainter oldDelegate) => true;
}

// Kratka pomocnicza na płótnie — te same proporcje/kolor co siatka tła apki.
class _CanvasGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = TC.ink.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    const step = 44.0;
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Ekran galerii — siatka miniatur odebranych rysunków. Klik = zwróć wybrany.
class GalleryScreen extends StatelessWidget {
  final List<ReceivedDrawing> history;
  final bool loading;

  const GalleryScreen({
    super.key,
    required this.history,
    required this.loading,
  });

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'przed chwilą';
    if (d.inMinutes < 60) return '${d.inMinutes} min temu';
    if (d.inHours < 24) return '${d.inHours} godz. temu';
    return '${d.inDays} dni temu';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historia')),
      body: PaperBackground(
        child: loading
          ? const Center(child: CircularProgressIndicator())
          : history.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Tu pojawią się Twoje rysunki —\nwysłane i odebrane. 🐱',
                      textAlign: TextAlign.center,
                      style: handStyle(size: 24),
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    childAspectRatio: 0.85,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: history.length,
                  itemBuilder: (context, i) {
                    final d = history[i];
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(d),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Container(
                                color: Colors.white,
                                child: CustomPaint(
                                  painter: ThumbnailPainter(d.strokes),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    d.outgoing
                                        ? Icons.north_east
                                        : Icons.south_west,
                                    size: 15,
                                    color: d.outgoing
                                        ? TC.brand
                                        : const Color(0xFF2E9E5B),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      d.outgoing
                                          ? 'do ${d.other}'
                                          : 'od ${d.other}',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  Text(
                                    _ago(d.createdAt),
                                    style: const TextStyle(
                                        fontSize: 11, color: TC.inkSoft),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
    );
  }
}

// Rysuje rysunek przeskalowany tak, by zmieścił się w kadrze miniatury.
class ThumbnailPainter extends CustomPainter {
  final List<Stroke> strokes;

  ThumbnailPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    // Bounding box wszystkich punktów.
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
    if (minX > maxX || minY > maxY) return; // brak punktów

    const pad = 8.0;
    final w = (maxX - minX) < 1 ? 1.0 : (maxX - minX);
    final h = (maxY - minY) < 1 ? 1.0 : (maxY - minY);
    final sx = (size.width - 2 * pad) / w;
    final sy = (size.height - 2 * pad) / h;
    final scale = sx < sy ? sx : sy;
    if (scale <= 0) return;

    // Wyśrodkowanie przeskalowanego rysunku.
    final dx = (size.width - w * scale) / 2 - minX * scale;
    final dy = (size.height - h * scale) / 2 - minY * scale;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    for (final stroke in strokes) {
      if (stroke.points.length < 2) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final p in stroke.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ThumbnailPainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}
