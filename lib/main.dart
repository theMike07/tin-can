import 'dart:convert' show base64Decode;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_gate.dart';
import 'chat_screen.dart';
import 'chime.dart';
import 'logo.dart';
import 'push.dart';
import 'theme.dart';
import 'widget_bridge.dart';

const kSupabaseUrl = 'https://safvbfwtqjlgcegnyckp.supabase.co';
const kSupabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNhZnZiZnd0cWpsZ2NlZ255Y2twIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI2NTg3NjAsImV4cCI6MjA5ODIzNDc2MH0.06giB9KYiw9BI1Q0FYijhn3-QO5PdcV9pZ0mi8ejS00';

// Globalny klucz nawigatora — klik w widżet otwiera czat z konkretną osobą.
final navigatorKey = GlobalKey<NavigatorState>();

// Push w TLE (apka zwinięta/zabita): odśwież widżety, żeby rysunek „sam
// wylądował" na ekranie głównym. Osobny izolat — własna inicjalizacja.
@pragma('vm:entry-point')
Future<void> tinCanBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    await Supabase.initialize(url: kSupabaseUrl, publishableKey: kSupabaseAnonKey);
  } catch (_) {
    // już zainicjalizowane w tym izolacie — w porządku
  }
  try {
    await refreshDrawingWidgets();
  } catch (e) {
    debugPrint('TINCAN_BG_WIDGET_ERROR: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: kSupabaseUrl,
    publishableKey: kSupabaseAnonKey,
  );
  await initFirebaseIfMobile();
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(tinCanBackgroundHandler);
  }
  await loadThemePref(); // wczytaj wybór trybu ciemnego przed pierwszym buildem
  runApp(const TinCanApp());
}

class TinCanApp extends StatefulWidget {
  const TinCanApp({super.key});

  @override
  State<TinCanApp> createState() => _TinCanAppState();
}

class _TinCanAppState extends State<TinCanApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 4: po uruchomieniu apki wyczyść powiadomienia z paska systemowego.
    clearDeliveredNotifications();
    // Klik w widżet: uri tincan://chat/<peerId>?label=... -> otwórz czat.
    if (isAndroidApp) {
      HomeWidget.initiallyLaunchedFromHomeWidget().then(_openChatFromWidget);
      HomeWidget.widgetClicked.listen(_openChatFromWidget);
    }
    // Push na pierwszym planie: odśwież widżety (rysunek/lajk), nawet gdy nie
    // jesteśmy w danym czacie.
    if (!kIsWeb) {
      FirebaseMessaging.onMessage.listen((_) => refreshDrawingWidgets());
    }
  }

  void _openChatFromWidget(Uri? uri) {
    if (uri == null || uri.scheme != 'tincan' || uri.host != 'chat') return;
    if (uri.pathSegments.isEmpty) return;
    // bez sesji nie ma dokąd nawigować — AuthGate pokaże logowanie
    if (Supabase.instance.client.auth.currentSession == null) return;
    final peerId = uri.pathSegments.first;
    final label = uri.queryParameters['label'] ?? 'Puszka';
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => DrawingScreen(peerId: peerId, peerLabel: label),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 4: po powrocie do apki (wznowienie z tła) też czyścimy powiadomienia.
    if (state == AppLifecycleState.resumed) {
      clearDeliveredNotifications();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Przebudowa całej apki, gdy zmienia się tryb ciemny. TC.dark ustawiamy
    // PRZED zbudowaniem motywu, żeby wszystkie kolory TC.* były spójne.
    return ValueListenableBuilder<bool>(
      valueListenable: appDarkMode,
      builder: (context, dark, _) {
        TC.dark = dark;
        // Pasek stanu i pasek nawigacji telefonu podążają za motywem: przy
        // przełączeniu na jasny ikony (godzina, powiadomienia) znów są ciemne.
        SystemChrome.setSystemUIOverlayStyle(
          (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
              .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: TC.paper,
            systemNavigationBarIconBrightness:
                dark ? Brightness.light : Brightness.dark,
          ),
        );
        return MaterialApp(
          title: 'Tin Can',
          debugShowCheckedModeBanner: false,
          theme: buildTinCanTheme(),
          navigatorKey: navigatorKey,
          home: const AuthGate(),
        );
      },
    );
  }
}

// Jedna kreska = kolor, grubość i lista punktów (w pikselach na razie).
class Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser; // gumka: wycinamy tusz (BlendMode.clear), nie malujemy
  // Tusz adaptacyjny (czarny↔biały): renderowany kontrastowo do koloru płótna
  // U KAŻDEGO odbiorcy (patrz adaptiveInkFor). `color` trzymany jako sensowny
  // fallback. Serializowany dodatkowym kluczem 'ink':1 (stare wersje go ignorują).
  final bool adaptive;

  Stroke({
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
    this.adaptive = false,
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
      if (adaptive) 'ink': 1,
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
    final ink = json['ink'];
    // Zgodność wstecz: dawny „ołówek" zapisany jako czysta czerń (000000) bez
    // flagi też traktujemy jako adaptacyjny — inaczej byłby niewidoczny na
    // ciemnym płótnie. Stałe kolory palety nigdy nie są czystą czernią.
    final adaptive = ink == 1 || ink == true || rgb == 0x000000;
    return Stroke(
      points: pts,
      color: Color.fromARGB(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF),
      width: (json['width'] as num).toDouble(),
      adaptive: adaptive,
    );
  }

  int get pointCount => points.length;
}

// Jeden rysunek w historii — wysłany albo odebrany.
class ReceivedDrawing {
  final String? id; // id wiersza w bazie (do oznaczania odczytu)
  final String sender;
  final String recipient;
  final bool outgoing; // true = ja wysłałem; false = przyszło do mnie
  final String other; // druga strona (do kogo / od kogo)
  final DateTime createdAt;
  final List<Stroke> strokes;
  DateTime? readAt; // kiedy odbiorca przeczytał (mutowalne — aktualizacja realtime)
  DateTime? likedAt; // kiedy odbiorca polubił (mutowalne)
  String? otherLabel; // ładna nazwa drugiej strony (@nazwa/e-mail) do historii

  // Do wyświetlenia: nazwa zamiast surowego id. Fallback = id.
  String get otherDisplay =>
      (otherLabel != null && otherLabel!.isNotEmpty) ? otherLabel! : other;

  ReceivedDrawing({
    this.id,
    required this.sender,
    required this.recipient,
    required this.outgoing,
    required this.other,
    required this.createdAt,
    required this.strokes,
    this.readAt,
    this.likedAt,
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
      id: row['id'] as String?,
      sender: sender,
      recipient: recipient,
      outgoing: outgoing,
      other: outgoing ? recipient : sender,
      createdAt:
          DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
      strokes: strokes,
      readAt: DateTime.tryParse(row['read_at']?.toString() ?? '')?.toLocal(),
      likedAt: DateTime.tryParse(row['liked_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

class DrawingScreen extends StatefulWidget {
  final String? peerId; // 1:1: user_id drugiej osoby
  final String? groupId; // grupa: id grupy (wtedy peerId == null)
  final String peerLabel; // etykieta w pasku (osoba albo nazwa grupy)
  final String? connectionId; // 1:1: id połączenia (do „usuń znajomego")

  const DrawingScreen({
    super.key,
    this.peerId,
    this.groupId,
    required this.peerLabel,
    this.connectionId,
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
  // Tusz adaptacyjny (czarny↔biały wg płótna) — domyślny „ołówek". Rysuje czarno
  // na jasnej kartce, biało na ciemnej, także u odbiorcy z innym płótnem.
  bool _adaptiveInk = true;
  double _brushWidth = 6.0; // domyślna grubość — zawsze ta sama przy wejściu
  bool _eraser = false;

  // Wejście rysowania: surowe zdarzenia (Listener) zamiast gestów pan —
  // kreska startuje DOKŁADNIE w punkcie dotknięcia, bez opóźnienia areny.
  int? _activePointer;
  Offset? _downPos;
  bool _strokeStarted = false;
  DateTime _lastTapUp = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastTapPos;

  // Ręczny wybór płótna (null = AUTO: papier na jasnym, noc na ciemnym).
  Color? _canvasChoice;
  Color get _canvasColor => _canvasChoice ?? autoCanvasColor();

  // Zdjęcie profilowe rozmówcy (base64) do nagłówka; null = inicjał.
  String? _peerAvatar;

  // Emotka dołączana do powiadomienia push u odbiorcy („X przysłał Ci rysunek ❤️").
  String _notifEmoji = '🥫';

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

  // Cofnij/ponów — stos zdjętych kresek (każda kreska = od dotknięcia do puszczenia).
  final List<Stroke> _redo = [];
  bool get _canUndo => _drawingMine && _strokes.isNotEmpty;
  bool get _canRedo => _drawingMine && _redo.isNotEmpty;

  // #5 lajki: rysunek OD kogoś aktualnie na płótnie (można go polubić dwuklikiem).
  ReceivedDrawing? _shownReceived;
  bool _heartBurst = false; // animacja serca przy polubieniu
  int _heartBurstId = 0;

  // Streak: liczba kolejnych dni z interakcją (rysunek/wiadomość) z peerem.
  int _streak = 0;

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
    _loadStreak();
    loadCanvasColor().then((c) {
      if (mounted) setState(() => _canvasChoice = c);
    });
    SharedPreferences.getInstance().then((p) {
      final e = p.getString('notif_emoji');
      if (mounted && e != null && e.isNotEmpty) {
        setState(() => _notifEmoji = e);
      }
    });
    _loadPeerAvatar();
  }

  // Awatar rozmówcy do nagłówka (tylko 1:1). Odporny na brak kolumny/wiersza.
  Future<void> _loadPeerAvatar() async {
    if (widget.peerId == null) return;
    try {
      final row = await supabase
          .from('profiles')
          .select()
          .eq('id', widget.peerId!)
          .maybeSingle();
      if (mounted && row != null) {
        setState(() => _peerAvatar = row['avatar_url'] as String?);
      }
    } catch (_) {}
  }

  // Wczytuje streak (kolejne dni z interakcją) — tylko dla czatów 1:1.
  Future<void> _loadStreak() async {
    if (widget.isGroup) return;
    try {
      final res = await supabase.rpc('get_streak', params: {'p_peer': peerId});
      if (mounted && res is int) setState(() => _streak = res);
    } catch (e) {
      debugPrint('TINCAN_STREAK_ERROR: $e');
    }
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
        // Odczyty i lajki: gdy odbiorca przeczyta/polubi MÓJ rysunek,
        // przychodzi UPDATE (read_at/liked_at) na wierszu, gdzie sender == ja.
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'drawings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender',
            value: myId,
          ),
          callback: _onDrawingUpdate,
        )
        .subscribe((status, [error]) {
          debugPrint('TINCAN_SUB: $status ${error ?? ''}');
        });
  }

  // Wczytanie historii odebranych rysunków z bazy (najnowsze pierwsze).
  Future<void> _loadHistory() async {
    try {
      // select() = wszystkie kolumny; dzięki temu brak kolumny read_at (przed
      // uruchomieniem read_receipts.sql) NIE wywala ładowania historii.
      final base = supabase.from('drawings').select();
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
      await _labelHistory(items);
      if (mounted) {
        setState(() {
          _history
            ..clear()
            ..addAll(items);
        });
        // 1: jeśli ostatni rysunek w wątku jest OD peera — odtwórz go z
        // animacją (jak „na żywo"), zamiast pokazywać od razu w całości.
        if (items.isNotEmpty && !items.first.outgoing) {
          _materialize(items.first.strokes, source: items.first);
          _markRead(items.first); // 3: wejście w czat = przeczytanie
        }
      }
    } catch (e) {
      debugPrint('TINCAN_HISTORY_ERROR: $e');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  // Uzupełnia ładne nazwy „od/do" w historii: 1:1 = peer; grupa = nadawcy.
  Future<void> _labelHistory(List<ReceivedDrawing> items) async {
    if (items.isEmpty) return;
    if (!widget.isGroup) {
      for (final it in items) {
        it.otherLabel = widget.peerLabel;
      }
      return;
    }
    final ids =
        items.where((e) => !e.outgoing).map((e) => e.sender).toSet().toList();
    final map = <String, String>{};
    if (ids.isNotEmpty) {
      try {
        final profs = await supabase
            .from('profiles')
            .select('id, username, email')
            .inFilter('id', ids);
        for (final p in (profs as List)) {
          final username = p['username'] as String?;
          final email = p['email'] as String?;
          map[p['id'] as String] = (username != null && username.isNotEmpty)
              ? username
              : (email ?? '?');
        }
      } catch (e) {
        debugPrint('TINCAN_LABEL_ERROR: $e');
      }
    }
    for (final it in items) {
      it.otherLabel =
          it.outgoing ? widget.peerLabel : (map[it.sender] ?? it.other);
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

    // Ładna nazwa „od kogo" w historii (1:1 od ręki; grupa — dociągnij).
    if (!widget.isGroup) {
      received.otherLabel = widget.peerLabel;
    } else {
      _labelHistory([received]).then((_) {
        if (mounted) setState(() {});
      });
    }

    setState(() => _history.insert(0, received));

    // #4: jeśli rysuję właśnie swoje (niewysłane) — odłóż je do kieszeni,
    // pokaż normalnie przychodzący rysunek, a MÓJ da się przywrócić ikoną.
    if (_drawingMine && _strokes.isNotEmpty) {
      _stashedMine = List<Stroke>.from(_strokes);
    }
    _materialize(received.strokes, source: received);
    _markRead(received); // 3: właśnie go widzę → oznacz jako przeczytany
    refreshDrawingWidgets(); // widżety na ekranie głównym też dostają rysunek

    // Miły "ding" — sygnał, że coś przyszło (Web Audio na web; na mobile cisza).
    playChime();
  }

  // 3: oznacz odebrany rysunek jako przeczytany (raz, tylko dla odebranych).
  Future<void> _markRead(ReceivedDrawing d) async {
    if (d.outgoing || d.id == null || d.readAt != null) return;
    d.readAt = DateTime.now(); // lokalnie od razu (unikamy podwójnego wywołania)
    try {
      await supabase.rpc('mark_read', params: {'p_id': d.id});
    } catch (e) {
      debugPrint('TINCAN_MARK_READ_ERROR: $e');
    }
  }

  // 3+5: nadawca dostaje na żywo odczyt (read_at) i lajk (liked_at) swojego rysunku.
  void _onDrawingUpdate(PostgresChangePayload payload) {
    final rec = payload.newRecord;
    final id = rec['id'] as String?;
    if (id == null) return;
    final idx = _history.indexWhere((d) => d.id == id);
    if (idx < 0) return;
    final readAt = DateTime.tryParse(rec['read_at']?.toString() ?? '')?.toLocal();
    final likedAt =
        DateTime.tryParse(rec['liked_at']?.toString() ?? '')?.toLocal();
    setState(() {
      if (readAt != null) _history[idx].readAt = readAt;
      _history[idx].likedAt = likedAt; // null = odlubione
    });
  }

  // #5: polub / odlub odebrany rysunek pokazany na płótnie (dwuklik lub serce).
  Future<void> _toggleLike() async {
    final d = _shownReceived;
    if (d == null || d.id == null) return;
    final liked = d.likedAt == null; // przełącz stan
    setState(() {
      d.likedAt = liked ? DateTime.now() : null;
      if (liked) {
        _heartBurst = true;
        _heartBurstId++; // restart animacji przy każdym polubieniu
      }
    });
    try {
      await supabase
          .rpc('set_like', params: {'p_id': d.id, 'p_liked': liked});
    } catch (e) {
      debugPrint('TINCAN_LIKE_ERROR: $e');
    }
  }

  // Wrzuca dany rysunek na płótno i odpala animację materializacji.
  void _materialize(List<Stroke> strokes, {ReceivedDrawing? source}) {
    setState(() {
      _strokes
        ..clear()
        ..addAll(strokes);
      _currentStroke = null;
      _materializing = true;
      _drawingMine = false; // płótno pokazuje teraz cudzy rysunek
      _redo.clear();
      // #5: który odebrany rysunek jest na płótnie (do polubienia dwuklikiem).
      _shownReceived = (source != null && !source.outgoing) ? source : null;
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
      _redo.clear();
      _shownReceived = null;
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
      // jeśli na płótnie był cudzy (odebrany) rysunek — zaczynamy na czysto.
      if (!_drawingMine) _strokes.clear();
      _drawingMine = true; // to jest mój rysunek — chroń go przed nadpisaniem
      _shownReceived = null; // rysuję swoje — nie ma czego lubić
      // Tusz adaptacyjny liczymy względem MOJEGO płótna (podgląd lokalny);
      // flaga `adaptive` sprawia, że u odbiorcy przeliczy się do JEGO płótna.
      final ink = _adaptiveInk ? adaptiveInkFor(_canvasColor) : _brushColor;
      _currentStroke = Stroke(
        points: [position],
        // Gumka wycina tusz (patrz DrawingPainter) — kolor bez znaczenia dla
        // renderu, ale zostaje biały dla zapisu i podglądu u odbiorcy.
        color: _eraser ? Colors.white : ink,
        width: _eraser ? 18.0 : _brushWidth,
        isEraser: _eraser,
        adaptive: !_eraser && _adaptiveInk,
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
        _redo.clear(); // nowa kreska kasuje możliwość „ponów"
      }
    });
  }

  // --- Surowe wejście wskaźnika (bez opóźnienia gestów) ---

  void _onPointerDown(PointerDownEvent e) {
    final pos = e.localPosition;
    // #5: dwuklik w odebrany rysunek = lajk (nie rozpoczyna kreski).
    if (_shownReceived != null &&
        _lastTapPos != null &&
        DateTime.now().difference(_lastTapUp).inMilliseconds < 300 &&
        (pos - _lastTapPos!).distance < 40) {
      _lastTapPos = null;
      _toggleLike();
      return;
    }
    if (_activePointer != null) return; // rysujemy już jednym palcem
    _activePointer = e.pointer;
    _downPos = pos;
    _strokeStarted = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer || _downPos == null) return;
    final pos = e.localPosition;
    if (!_strokeStarted) {
      if ((pos - _downPos!).distance < 1.5) return; // czekaj na drgnięcie
      _startStroke(_downPos!); // start dokładnie w punkcie dotknięcia
      _strokeStarted = true;
    }
    _addPoint(pos);
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _activePointer) return;
    if (_strokeStarted) {
      _endStroke();
    } else {
      // stuknięcie bez rysowania — zapamiętaj do wykrycia dwukliku (lajk).
      _lastTapUp = DateTime.now();
      _lastTapPos = _downPos;
    }
    _activePointer = null;
    _downPos = null;
    _strokeStarted = false;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _activePointer) return;
    if (_strokeStarted) _endStroke();
    _activePointer = null;
    _downPos = null;
    _strokeStarted = false;
  }

  // Cofnij ostatnią kreskę (na stos redo).
  void _undo() {
    if (!_canUndo) return;
    setState(() => _redo.add(_strokes.removeLast()));
  }

  // Ponów cofniętą kreskę.
  void _redoStroke() {
    if (!_canRedo) return;
    setState(() => _strokes.add(_redo.removeLast()));
  }

  void _clear() {
    _materializing = false;
    _revealController.stop();
    setState(() {
      _strokes.clear();
      _currentStroke = null;
      _drawingMine = false;
      _stashedMine = null;
      _redo.clear();
      _shownReceived = null;
    });
  }

  // Wysyłka: kreski -> JSON -> tabela drawings. Po wysłaniu czyścimy płótno.
  Future<void> _send() async {
    if (_strokes.isEmpty) return;
    final snapshot = List<Stroke>.from(_strokes);
    final strokesJson = snapshot.map((s) => s.toJson()).toList();
    try {
      String? newId;
      if (widget.isGroup) {
        await supabase.rpc('send_group_drawing', params: {
          'p_group_id': widget.groupId,
          'p_strokes': strokesJson,
        });
      } else {
        // .select() zwraca wstawiony wiersz — bierzemy id do śledzenia odczytu.
        // notif_emoji = emotka do powiadomienia; jeśli kolumny jeszcze nie ma
        // w bazie (przed migracją), ponawiamy wysyłkę bez niej.
        final row = <String, dynamic>{
          'sender': myId,
          'recipient': widget.peerId,
          'strokes': strokesJson,
          'notif_emoji': _notifEmoji,
        };
        Map<String, dynamic> inserted;
        try {
          inserted =
              await supabase.from('drawings').insert(row).select('id').single();
        } on PostgrestException {
          row.remove('notif_emoji');
          inserted =
              await supabase.from('drawings').insert(row).select('id').single();
        }
        newId = inserted['id'] as String?;
      }
      // Do lokalnej historii (natychmiastowy podgląd; reload i tak dociągnie).
      setState(() {
        _history.insert(
          0,
          ReceivedDrawing(
            id: newId,
            sender: myId,
            recipient: widget.peerId ?? myId,
            outgoing: true,
            other: widget.peerId ?? '',
            createdAt: DateTime.now(),
            strokes: snapshot,
          )..otherLabel = widget.peerLabel,
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
      _materialize(picked.strokes, source: picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Małe logo wycentrowane na górze, pod nim: profilowe + imię + streak.
        centerTitle: true,
        toolbarHeight: 76,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TinCanLogo(width: 19),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _peerAvatarBadge(),
                const SizedBox(width: 8),
                Flexible(
                  child:
                      Text(widget.peerLabel, overflow: TextOverflow.ellipsis),
                ),
                if (_streak > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: TC.coral.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('🔥 $_streak',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: TC.coral600)),
                  ),
                ],
              ],
            ),
          ],
        ),
        actions: [
          _buildFriendMenu(),
        ],
        // Drugi pasek: funkcje sesji rysowania (Wyślij wyeksponowany na środku)
        // + cienki pasek postępu materializacji pod spodem.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(59),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFunctionsBar(),
              SizedBox(
                height: 3,
                child: _materializing
                    ? LinearProgressIndicator(value: _reveal, minHeight: 3)
                    : null,
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildToolbar(),
      body: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: Container(
              color: _canvasColor,
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
                    child: CustomPaint(painter: _CanvasGridPainter(_canvasColor)),
                  ),
                  CustomPaint(
                    painter: DrawingPainter(
                      strokes: _strokes,
                      currentStroke: _currentStroke,
                      reveal: _reveal,
                      canvasColor: _canvasColor,
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
          // #5: mały wskaźnik lajka przy odebranym rysunku (też do stuknięcia).
          if (_shownReceived != null)
            Positioned(
              right: 16,
              bottom: 16,
              child: GestureDetector(
                onTap: _toggleLike,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: TC.ink.withValues(alpha: 0.15),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(
                    _shownReceived!.likedAt != null
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: _shownReceived!.likedAt != null
                        ? TC.coral
                        : TC.inkSoft,
                    size: 24,
                  ),
                ),
              ),
            ),
          // #5: animacja serca po polubieniu (dwuklikiem).
          if (_heartBurst)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(_heartBurstId),
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOut,
                    onEnd: () {
                      if (mounted) setState(() => _heartBurst = false);
                    },
                    builder: (_, t, _) {
                      final scale = 0.5 + t * 0.9;
                      final opacity =
                          (t < 0.4 ? t / 0.4 : (1 - (t - 0.4) / 0.6))
                              .clamp(0.0, 1.0);
                      return Opacity(
                        opacity: opacity,
                        child: Transform.scale(
                          scale: scale,
                          child: const Icon(Icons.favorite,
                              color: TC.coral, size: 130),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- Górny pasek funkcji + menu znajomego ---

  // Kółko profilowe rozmówcy w nagłówku (zdjęcie albo inicjał na gradiencie),
  // z subtelną obwódką, żeby nie zlewało się z tłem.
  Widget _peerAvatarBadge() {
    const d = 30.0;
    Widget inner;
    final b64 = _peerAvatar;
    if (b64 != null && b64.isNotEmpty) {
      try {
        inner = Image.memory(base64Decode(b64),
            width: d, height: d, fit: BoxFit.cover, gaplessPlayback: true);
      } catch (_) {
        inner = _peerInitialAvatar(d);
      }
    } else {
      inner = _peerInitialAvatar(d);
    }
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: TC.ink.withValues(alpha: 0.15)),
      ),
      child: ClipOval(child: inner),
    );
  }

  Widget _peerInitialAvatar(double d) {
    final s = widget.peerLabel.replaceAll('@', '').trim();
    final initial = s.isEmpty ? '🥫' : s.substring(0, 1).toUpperCase();
    return Container(
      width: d,
      height: d,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: TC.brandGradient,
      ),
      alignment: Alignment.center,
      child: Text(initial,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
    );
  }

  void _openChat() {
    if (widget.peerId == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          ChatScreen(peerId: widget.peerId!, peerLabel: widget.peerLabel),
    ));
  }

  void _pinWidget(bool tall) {
    if (widget.peerId == null) return;
    pinDrawingWidget(
        peerId: widget.peerId!, label: widget.peerLabel, tall: tall);
  }

  Future<void> _removeFriend() async {
    final connId = widget.connectionId;
    if (connId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Usunąć znajomego?'),
        content: Text('Usunąć połączenie z ${widget.peerLabel}? '
            'Rysunki zostaną w historii, ale nie wyślecie już nowych.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TC.coral600),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Usuń'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await supabase.rpc('remove_connection', params: {'conn_id': connId});
      if (mounted) Navigator.of(context).pop(); // wróć do listy puszek
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd: $e')));
      }
    }
  }

  // ⋮ przy nazwie — kolor płótna + (dla 1:1) akcje znajomego jak na liście.
  Widget _buildFriendMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Więcej',
      onSelected: (v) {
        if (v == 'canvas') _openCanvasColorSheet();
        if (v == 'emoji') _openNotifEmojiSheet();
        if (v == 'chat') _openChat();
        if (v == 'widget_sq') _pinWidget(false);
        if (v == 'widget_tall') _pinWidget(true);
        if (v == 'remove') _removeFriend();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'canvas',
          child: ListTile(
            leading: Icon(Icons.palette_outlined),
            title: Text('Kolor płótna'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'emoji',
          child: ListTile(
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: Text('Emotka powiadomienia   $_notifEmoji'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (!widget.isGroup)
          const PopupMenuItem(
            value: 'chat',
            child: ListTile(
              leading: Icon(Icons.chat_bubble_outline),
              title: Text('Napisz wiadomość'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (isAndroidApp && !widget.isGroup) ...const [
          PopupMenuItem(
            value: 'widget_sq',
            child: ListTile(
              leading: Icon(Icons.crop_square),
              title: Text('Widżet: rysunek (kwadrat)'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'widget_tall',
            child: ListTile(
              leading: Icon(Icons.crop_portrait),
              title: Text('Widżet: rysunek (pion)'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
        if (widget.connectionId != null)
          const PopupMenuItem(
              value: 'remove', child: Text('Usuń znajomego')),
      ],
    );
  }

  // Pełna biblioteka emoji (tekst Unicode, systemowy font — zero assetów).
  // Wybrana emotka leci z rysunkiem i pojawia się w powiadomieniu odbiorcy.
  void _openNotifEmojiSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Text(
                'Z jaką emotką ma przyjść powiadomienie o Twoim rysunku?',
                style: Theme.of(ctx).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(
              height: 330,
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  setState(() => _notifEmoji = emoji.emoji);
                  SharedPreferences.getInstance()
                      .then((p) => p.setString('notif_emoji', emoji.emoji));
                  Navigator.pop(ctx);
                },
                config: Config(
                  height: 330,
                  emojiViewConfig: EmojiViewConfig(
                    backgroundColor: TC.paper,
                    emojiSizeMax: 26,
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    backgroundColor: TC.paper,
                    indicatorColor: TC.brand,
                    iconColorSelected: TC.brand,
                  ),
                  bottomActionBarConfig:
                      const BottomActionBarConfig(enabled: false),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: TC.paper,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Wybór koloru płótna (auto = podąża za motywem; ręczny nadpisuje).
  void _openCanvasColorSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Kolor płótna',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Auto podąża za motywem apki (jasny papier / ciemna noc). '
                'Ręczny wybór nadpisuje — np. biała kartka w trybie ciemnym.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _autoCanvasSwatch(ctx),
                  for (final c in kCanvasColors) _canvasSwatch(c, ctx),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _pickCanvas(Color? c, BuildContext sheetCtx) {
    setState(() => _canvasChoice = c);
    saveCanvasColor(c);
    // Widżety rysunku mają to samo płótno co czat — odśwież je od razu.
    refreshDrawingWidgets();
    Navigator.pop(sheetCtx);
  }

  BoxDecoration _swatchDecoration(bool selected, {Color? color, Gradient? g}) =>
      BoxDecoration(
        color: color,
        gradient: g,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? TC.brand : TC.ink.withValues(alpha: 0.2),
          width: selected ? 4 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: TC.ink.withValues(alpha: 0.1),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      );

  // Auto: pół jasne / pół ciemne + ikonka. Wybrane, gdy brak ręcznego koloru.
  Widget _autoCanvasSwatch(BuildContext sheetCtx) {
    final selected = _canvasChoice == null;
    return GestureDetector(
      onTap: () => _pickCanvas(null, sheetCtx),
      child: Container(
        width: 58,
        height: 58,
        alignment: Alignment.center,
        decoration: _swatchDecoration(
          selected,
          g: const LinearGradient(
            colors: [kCanvasLight, kCanvasLight, kCanvasDark, kCanvasDark],
            stops: [0.0, 0.5, 0.5, 1.0],
          ),
        ),
        child: const Icon(Icons.brightness_auto, color: TC.brand, size: 22),
      ),
    );
  }

  Widget _canvasSwatch(Color c, BuildContext sheetCtx) {
    final selected =
        _canvasChoice != null && _canvasChoice!.toARGB32() == c.toARGB32();
    return GestureDetector(
      onTap: () => _pickCanvas(c, sheetCtx),
      child: Container(
        width: 58,
        height: 58,
        decoration: _swatchDecoration(selected, color: c),
      ),
    );
  }

  // Drugi pasek: czat · historia · [WYŚLIJ] · czas · kosz.
  Widget _buildFunctionsBar() {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.ink.withValues(alpha: 0.08))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Czat',
            color: TC.inkSoft,
            onPressed: widget.isGroup ? null : _openChat,
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: _history.isNotEmpty,
              label: Text('${_history.length}'),
              child: const Icon(Icons.collections_outlined),
            ),
            tooltip: 'Historia',
            color: TC.inkSoft,
            onPressed: _openGallery,
          ),
          // WYŚLIJ — najbardziej wyeksponowany, na środku
          Material(
            color: TC.brand,
            shape: const CircleBorder(),
            elevation: 2,
            shadowColor: TC.brand.withValues(alpha: 0.5),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _send,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.send, color: Colors.white, size: 24),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.timer_outlined),
            tooltip: 'Czas odrysowywania',
            color: TC.inkSoft,
            onPressed: _openSpeedSheet,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Wyczyść',
            color: TC.inkSoft,
            onPressed: _clear,
          ),
        ],
      ),
    );
  }

  // --- Pasek narzędzi (pędzel) ---

  // Pierwsze pole palety to tusz adaptacyjny (czarny↔biały) — renderowane
  // osobno (_adaptiveSwatch). Pozostałe kolory są stałe niezależnie od płótna.
  static const List<Color> _palette = [
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF8E24AA),
    Color(0xFFEC407A),
  ];

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
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                onPressed: _canUndo ? _undo : null,
                icon: const Icon(Icons.undo),
                tooltip: 'Cofnij',
                color: TC.inkSoft,
              ),
              IconButton(
                onPressed: _canRedo ? _redoStroke : null,
                icon: const Icon(Icons.redo),
                tooltip: 'Ponów',
                color: TC.inkSoft,
              ),
              Container(
                width: 1,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: TC.ink.withValues(alpha: 0.14),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      _adaptiveSwatch(),
                      for (final c in _palette) _colorSwatch(c),
                      Container(
                        width: 1,
                        height: 28,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        color: TC.ink.withValues(alpha: 0.14),
                      ),
                      _widthButton(),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(Color c) {
    final selected = !_eraser && !_adaptiveInk && _brushColor == c;
    return GestureDetector(
      onTap: () => setState(() {
        _brushColor = c;
        _adaptiveInk = false;
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

  // Tusz adaptacyjny: pokazuje kolor, jaki realnie zostawi na AKTUALNYM płótnie
  // (czerń na jasnym, biel na ciemnym). Dwubarwna obwódka podpowiada zmienność.
  Widget _adaptiveSwatch() {
    final display = adaptiveInkFor(_canvasColor);
    final selected = !_eraser && _adaptiveInk;
    return GestureDetector(
      onTap: () => setState(() {
        _adaptiveInk = true;
        _eraser = false;
      }),
      child: Container(
        width: 30,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: display,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? TC.brand : TC.inkSoft.withValues(alpha: 0.55),
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  // Przycisk grubości: kropka w rozmiarze aktualnej grubości -> otwiera suwak.
  Widget _widthButton() {
    final active = !_eraser;
    final vis = _brushWidth.clamp(4.0, 26.0);
    return InkWell(
      onTap: _openWidthSheet,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 40,
        width: 44,
        alignment: Alignment.center,
        child: Container(
          width: vis,
          height: vis,
          decoration: BoxDecoration(
            color: active ? TC.ink : TC.inkSoft.withValues(alpha: 0.35),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  // Suwak grubości rysika (2–20, 10 stopni) — jak arkusz czasu odrysowywania.
  void _openWidthSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Grubość rysika',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 18),
                    // Podgląd na tle AKTUALNEGO płótna + obwódka — dzięki temu
                    // zmiana grubości np. czarnego rysika na ciemnym motywie jest
                    // widoczna (bez tła czarny na czarnym byłby niewidoczny).
                    Center(
                      child: Container(
                        width: double.infinity,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _canvasColor,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: TC.ink.withValues(alpha: 0.18)),
                        ),
                        child: Container(
                          width: _brushWidth * 2 + 24,
                          height: _brushWidth,
                          decoration: BoxDecoration(
                            color: _adaptiveInk
                                ? adaptiveInkFor(_canvasColor)
                                : _brushColor,
                            borderRadius: BorderRadius.circular(_brushWidth),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Slider(
                      min: 2,
                      max: 20,
                      divisions: 9,
                      value: _brushWidth.clamp(2.0, 20.0),
                      label: '${_brushWidth.round()} px',
                      onChanged: (v) {
                        setSheet(() {});
                        setState(() {
                          _brushWidth = v;
                          _eraser = false;
                        });
                      },
                    ),
                    Center(
                      child: Text('${_brushWidth.round()} px',
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
}

class DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  // Ułamek 0..1 — ile punktów (w kolejności rysowania, przez wszystkie kreski)
  // odsłonić. 1.0 = cały rysunek. Używane do "materializacji" odebranego rysunku.
  final double reveal;
  // Kolor płótna — potrzebny, by tusz adaptacyjny (czarny↔biały) renderować
  // kontrastowo do TEGO płótna, także dla rysunków przyjętych od innej osoby.
  final Color canvasColor;

  DrawingPainter({
    required this.strokes,
    required this.currentStroke,
    this.reveal = 1.0,
    this.canvasColor = const Color(0xFFFFFFFF),
  });

  // Rysuje kreskę tylko do `count` pierwszych punktów (count >= length = cała).
  void _drawStroke(Canvas canvas, Stroke stroke, int count) {
    final n = count.clamp(0, stroke.points.length);
    if (n < 2) return;

    final paint = Paint()
      ..color = stroke.adaptive ? adaptiveInkFor(canvasColor) : stroke.color
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
  final Color canvasColor;
  _CanvasGridPainter(this.canvasColor);

  @override
  void paint(Canvas canvas, Size size) {
    // Kolor kratki kontrastuje z płótnem (ciemny na jasnym, jasny na ciemnym).
    final line = Paint()
      ..color = contrastInk(canvasColor).withValues(alpha: 0.06)
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
  bool shouldRepaint(covariant _CanvasGridPainter oldDelegate) =>
      oldDelegate.canvasColor != canvasColor;
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
    if (d.inMinutes < 1) return 'teraz';
    if (d.inMinutes < 60) return '${d.inMinutes} min temu';
    if (d.inHours < 24) return '${d.inHours} h temu';
    return '${d.inDays} dni temu';
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Container(
                                      color: Colors.white,
                                      child: CustomPaint(
                                        painter: ThumbnailPainter(d.strokes),
                                      ),
                                    ),
                                  ),
                                  if (d.likedAt != null)
                                    const Positioned(
                                      right: 6,
                                      bottom: 6,
                                      child: Icon(Icons.favorite,
                                          color: TC.coral, size: 18),
                                    ),
                                ],
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
                                          ? 'do ${d.otherDisplay}'
                                          : 'od ${d.otherDisplay}',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  if (d.outgoing) ...[
                                    Icon(
                                      d.readAt != null
                                          ? Icons.done_all
                                          : Icons.done,
                                      size: 15,
                                      // ✓✓ odczytane = wyraźny fiolet
                                      color: d.readAt != null
                                          ? const Color(0xFF7C4DFF)
                                          : TC.inkSoft,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      d.readAt != null
                                          ? _hhmm(d.readAt!)
                                          : _ago(d.createdAt),
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: d.readAt != null
                                              ? const Color(0xFF7C4DFF)
                                              : TC.inkSoft),
                                    ),
                                  ] else
                                    Text(
                                      _ago(d.createdAt),
                                      style: TextStyle(
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
  final Color bg; // tło miniatury — do przeliczenia tuszu adaptacyjnego

  ThumbnailPainter(this.strokes, {this.bg = const Color(0xFFFFFFFF)});

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
        ..color = stroke.adaptive ? adaptiveInkFor(bg) : stroke.color
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
