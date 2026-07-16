import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_screen.dart';
import 'logo.dart';
import 'main.dart';
import 'push.dart';
import 'theme.dart';
import 'widget_bridge.dart';

// Google: wymaga konfiguracji w Google Cloud + Supabase (Client ID/Secret).
const bool kGoogleReady = true;

SupabaseClient get _supabase => Supabase.instance.client;

// Brama: niezalogowany -> ekran logowania; zalogowany -> ekran główny.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: _supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = _supabase.auth.currentSession;
        return session == null ? const LoginScreen() : const HomeScreen();
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isRegister = false;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Podaj e-mail i hasło.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      if (_isRegister) {
        final res =
            await _supabase.auth.signUp(email: email, password: password);
        // Brak sesji = włączone potwierdzanie e-mail. Przy wyłączonym
        // potwierdzaniu od razu jest sesja i AuthGate przełączy na HomeScreen.
        if (res.session == null && mounted) {
          setState(() => _info =
              'Konto utworzone. Sprawdź e-mail, potwierdź, a potem zaloguj się.');
        }
      } else {
        await _supabase.auth
            .signInWithPassword(email: email, password: password);
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Coś poszło nie tak: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    if (!kGoogleReady) {
      setState(() {
        _error = null;
        _info = 'Logowanie Google dodamy w następnym kroku — na razie e-mail.';
      });
      return;
    }
    try {
      await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        // Web: powrót na tę samą stronę. Mobile: deep link z powrotem do apki.
        redirectTo:
            kIsWeb ? Uri.base.origin : 'pl.themike07.tincan://login-callback',
      );
    } catch (e) {
      setState(() => _error = 'Logowanie Google nie powiodło się: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PaperBackground(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 384),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  const Center(child: TinCanLogo(width: 128)),
                  const SizedBox(height: 20),
                  Text(
                    'Tin Can',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          fontSize: 46,
                          height: 1.0,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      'dwie puszki, jeden sznurek',
                      style: handStyle(size: 24),
                    ),
                  ),
                  const SizedBox(height: 26),
                  GlassCard(
                    glow: true,
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Eyebrow(_isRegister ? 'Nowe konto' : 'Witaj ponownie'),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'E-mail',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          onSubmitted: (_) => _busy ? null : _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Hasło',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!,
                              style: const TextStyle(color: TC.coral600)),
                        ],
                        if (_info != null) ...[
                          const SizedBox(height: 12),
                          Text(_info!,
                              style: const TextStyle(
                                  color: Color(0xFF2E9E5B))),
                        ],
                        const SizedBox(height: 20),
                        PrimaryPillButton(
                          label: _isRegister ? 'Zarejestruj się' : 'Zaloguj się',
                          busy: _busy,
                          onPressed: _busy ? null : _submit,
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _isRegister = !_isRegister;
                                    _error = null;
                                    _info = null;
                                  }),
                          child: Text(_isRegister
                              ? 'Masz już konto? Zaloguj się'
                              : 'Nie masz konta? Zarejestruj się'),
                        ),
                        Row(
                          children: [
                            Expanded(
                                child: Divider(
                                    color: TC.ink.withValues(alpha: 0.12))),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Text('albo',
                                  style: TextStyle(
                                      color: TC.inkSoft, fontSize: 13)),
                            ),
                            Expanded(
                                child: Divider(
                                    color: TC.ink.withValues(alpha: 0.12))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _google,
                          icon: const Icon(Icons.g_mobiledata, size: 28),
                          label: const Text('Kontynuuj z Google'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Jedna „puszka" = połączenie z drugą osobą (id, e-mail, nazwa).
class Puszka {
  final String connectionId;
  final String otherId;
  final String otherEmail;
  final String? otherUsername;
  final String? otherAvatar; // base64 zdjęcia profilowego (opcjonalnie)
  final String status; // 'pending' | 'accepted'
  final bool requestedByMe; // czy JA wysłałem zaproszenie
  Puszka({
    required this.connectionId,
    required this.otherId,
    required this.otherEmail,
    required this.otherUsername,
    required this.otherAvatar,
    required this.status,
    required this.requestedByMe,
  });

  // Tytuł puszki: @nazwa jeśli jest, inaczej e-mail.
  String get label => (otherUsername != null && otherUsername!.isNotEmpty)
      ? otherUsername!
      : otherEmail;
}

// Ekran główny po zalogowaniu — lista puszek + dodawanie po e-mailu.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;
  String? _error;
  String? _myUsername;
  String? _myAvatar; // base64 mojego zdjęcia profilowego
  List<Puszka> _puszki = [];
  List<Map<String, dynamic>> _groups = []; // #3: grupy (id, name)
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _load();
    registerPushToken(); // zarejestruj urządzenie do powiadomień push
    // Przebuduj ekran przy zmianie motywu — bez tego karty czytające TC.*
    // (bez zależności od Theme.of) zostawały na kolorach starego trybu.
    appDarkMode.addListener(_onThemeChanged);
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appDarkMode.removeListener(_onThemeChanged);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = _supabase.auth.currentUser!.id;

      // moja nazwa użytkownika + zdjęcie. select() = wszystkie kolumny, dzięki
      // czemu brak kolumny avatar_url (przed migracją) NIE wywala ekranu.
      final myProfile =
          await _supabase.from('profiles').select().eq('id', me).maybeSingle();
      _myUsername = myProfile?['username'] as String?;
      _myAvatar = myProfile?['avatar_url'] as String?;

      final conns = await _supabase
          .from('connections')
          .select('id, user_a, user_b, status, requested_by');

      final otherIds = <String>[];
      final connByOther = <String, Map<String, dynamic>>{};
      for (final c in (conns as List)) {
        final a = c['user_a'] as String;
        final b = c['user_b'] as String;
        final other = a == me ? b : a;
        otherIds.add(other);
        connByOther[other] = c as Map<String, dynamic>;
      }

      final profById = <String, Map<String, dynamic>>{};
      if (otherIds.isNotEmpty) {
        final profs = await _supabase
            .from('profiles')
            .select()
            .inFilter('id', otherIds);
        for (final p in (profs as List)) {
          profById[p['id'] as String] = p as Map<String, dynamic>;
        }
      }

      final puszki = otherIds.map((id) {
        final p = profById[id];
        final c = connByOther[id]!;
        return Puszka(
          connectionId: c['id'] as String,
          otherId: id,
          otherEmail: (p?['email'] as String?) ?? '—',
          otherUsername: p?['username'] as String?,
          otherAvatar: p?['avatar_url'] as String?,
          status: (c['status'] as String?) ?? 'accepted',
          requestedByMe: c['requested_by'] == me,
        );
      }).toList();

      final gs = await _supabase.from('groups').select('id, name');
      final groups = (gs as List).cast<Map<String, dynamic>>();

      if (mounted) {
        setState(() {
          _puszki = puszki;
          _groups = groups;
          _loading = false;
        });
        // Widżety na ekranie głównym: dociągnij najnowsze rysunki.
        refreshDrawingWidgets();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _editUsername() async {
    final controller = TextEditingController(text: _myUsername ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nazwa użytkownika'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nazwa (3–20: litery, cyfry, _)',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    try {
      final res = await _supabase
          .rpc('set_username', params: {'new_username': value.trim()});
      final status = res as String?;
      final msg = switch (status) {
        'ok' => 'Nazwa ustawiona: ${value.trim()}',
        'taken' => 'Ta nazwa jest już zajęta.',
        'invalid' => 'Niedozwolona nazwa (3–20 znaków: litery, cyfry, _).',
        _ => 'Nie udało się ($status).',
      };
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      if (status == 'ok') _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd: $e')));
      }
    }
  }

  // #3: utwórz grupę — nazwa + wybór członków spośród zaakceptowanych znajomych.
  Future<void> _createGroup() async {
    final accepted = _puszki.where((p) => p.status == 'accepted').toList();
    if (accepted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Najpierw dodaj znajomych — z nich tworzysz grupę.')));
      return;
    }
    final nameCtrl = TextEditingController();
    final selected = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        return AlertDialog(
          title: const Text('Nowa grupa'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Nazwa grupy', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Członkowie:')),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: accepted
                        .map((p) => CheckboxListTile(
                              value: selected.contains(p.otherId),
                              title: Text(p.label),
                              onChanged: (v) => setSt(() {
                                if (v == true) {
                                  selected.add(p.otherId);
                                } else {
                                  selected.remove(p.otherId);
                                }
                              }),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Anuluj')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Utwórz')),
          ],
        );
      }),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty || selected.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Podaj nazwę i zaznacz min. jedną osobę.')));
      }
      return;
    }
    try {
      await _supabase.rpc('create_group',
          params: {'p_name': name, 'p_member_ids': selected.toList()});
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Grupa „$name" utworzona 👥')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd: $e')));
      }
    }
  }

  Future<void> _addByEmail() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dodaj osobę'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nazwa użytkownika lub e-mail',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Dodaj'),
          ),
        ],
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    try {
      final res = await _supabase
          .rpc('add_connection', params: {'identifier': value.trim()});
      final status = res as String?;
      final msg = switch (status) {
        'ok' => 'Zaproszenie wysłane 📨',
        'not_found' => 'Nie znaleziono osoby o tej nazwie lub e-mailu.',
        'self' => 'To Ty 🙂',
        'not_authenticated' => 'Najpierw się zaloguj.',
        _ => 'Nie udało się ($status).',
      };
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      if (status == 'ok') _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd: $e')));
      }
    }
  }

  // #2: usuwanie znajomego / anulowanie zaproszenia.
  Future<void> _doRemove(String connId) async {
    try {
      await _supabase.rpc('remove_connection', params: {'conn_id': connId});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd: $e')));
      }
    }
  }

  Future<void> _removeFriend(String connId, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Usunąć znajomego?'),
        content: Text(
            'Usunąć połączenie z $label? Rysunki zostaną w historii, ale nie wyślecie już nowych.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Usuń'),
          ),
        ],
      ),
    );
    if (ok == true) _doRemove(connId);
  }

  // #1: akceptacja/odrzucenie zaproszenia.
  Future<void> _respond(String connId, bool accept) async {
    try {
      final res = await _supabase.rpc('respond_connection',
          params: {'conn_id': connId, 'accept': accept});
      final status = res as String?;
      final msg = switch (status) {
        'accepted' => 'Zaakceptowano 🥫',
        'rejected' => 'Odrzucono',
        _ => 'Nie udało się ($status).',
      };
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _supabase.auth.currentUser;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TinCanLogo(width: 30),
            const SizedBox(width: 10),
            const Text('Twoje puszki'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Nowa grupa',
            onPressed: _createGroup,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Odśwież',
            onPressed: _load,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Konto',
            onSelected: (v) {
              if (v == 'theme') {
                setDarkMode(!appDarkMode.value)
                    // widżety na ekranie głównym też przełącz na nowy motyw
                    .then((_) => refreshDrawingWidgets());
              }
              if (v == 'logout') _supabase.auth.signOut();
              if (v == 'delete') _deleteAccount();
              if (v == 'chats_widget') _configChatsWidget();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'theme',
                child: ListTile(
                  leading: Icon(appDarkMode.value
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined),
                  title: Text(
                      appDarkMode.value ? 'Tryb jasny' : 'Tryb ciemny'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (isAndroidApp)
                const PopupMenuItem(
                  value: 'chats_widget',
                  child: ListTile(
                    leading: Icon(Icons.widgets_outlined),
                    title: Text('Widżet: szybkie czaty'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Wyloguj'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_forever, color: TC.coral600),
                  title: Text('Usuń konto',
                      style: TextStyle(color: TC.coral600)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addByEmail,
        icon: const Icon(Icons.add),
        label: const Text('Dodaj'),
      ),
      body: PaperBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Błąd ładowania: $_error',
                          textAlign: TextAlign.center),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                        child: GlassCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: _avatarMenu,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    _profileAvatar(_myAvatar, 48),
                                    Positioned(
                                      right: -2,
                                      bottom: -2,
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: TC.brand,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: TC.paper, width: 2),
                                        ),
                                        child: const Icon(Icons.photo_camera,
                                            size: 11, color: Colors.white),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: GestureDetector(
                                  onTap: _editUsername,
                                  behavior: HitTestBehavior.opaque,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _myUsername != null &&
                                                _myUsername!.isNotEmpty
                                            ? _myUsername!
                                            : 'Ustaw nazwę użytkownika',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: TC.ink,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        user?.email ?? '—',
                                        style: TextStyle(
                                            fontSize: 13, color: TC.inkSoft),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: _editUsername,
                                icon: const Icon(Icons.edit,
                                    size: 18, color: TC.brand),
                                tooltip: 'Zmień nazwę',
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(child: _buildList()),
                    ],
                  ),
      ),
    );
  }

  // Kwadratowy awatar z zaokrągleniem — spójny leading dla pozycji list.
  Widget _avatarBox(Color bg, Widget child) => Container(
        width: 44,
        height: 44,
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
        alignment: Alignment.center,
        child: child,
      );

  String _initial(String label) {
    final s = label.replaceAll('@', '').trim();
    return s.isEmpty ? '?' : s.substring(0, 1).toUpperCase();
  }

  // Dekoduje base64 na widżet obrazka; null/uszkodzone -> fallback.
  Widget? _decodedImage(String? b64, double size, double radius) {
    if (b64 == null || b64.isEmpty) return null;
    try {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          base64Decode(b64),
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  // Moje kółko profilowe: zdjęcie albo brandowy placeholder z logo.
  Widget _profileAvatar(String? b64, double size) {
    return _decodedImage(b64, size, size) ??
        Container(
          width: size,
          height: size,
          decoration:
              const BoxDecoration(color: TC.brand100, shape: BoxShape.circle),
          alignment: Alignment.center,
          // Kółko jest ZAWSZE jasne (brand100), więc kropki na stałe ciemne —
          // auto (białe w ciemnym motywie) zlewałoby się z tym tłem.
          child: TinCanLogo(width: size * 0.62, dot: const Color(0xFF201D2E)),
        );
  }

  // Leading znajomego: zdjęcie albo inicjał na brandowym tle.
  Widget _friendLeading(String? b64, String label) {
    return _decodedImage(b64, 44, 13) ??
        _avatarBox(
          TC.brand100,
          Text(_initial(label),
              style: const TextStyle(
                  color: TC.brand700,
                  fontWeight: FontWeight.w700,
                  fontSize: 18)),
        );
  }

  // Menu zdjęcia profilowego: wybierz / usuń.
  Future<void> _avatarMenu() async {
    final has = _myAvatar != null && _myAvatar!.isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Wybierz zdjęcie'),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (has)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: TC.coral600),
                title: const Text('Usuń zdjęcie'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == 'pick') await _pickAvatar();
    if (action == 'remove') await _saveAvatar(null);
  }

  // Wybór z galerii -> skalowanie 256px + kompresja -> base64 -> zapis.
  Future<void> _pickAvatar() async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 72,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 400 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Zdjęcie za duże — wybierz mniejsze.')));
        }
        return;
      }
      await _saveAvatar(base64Encode(bytes));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Nie udało się: $e')));
      }
    }
  }

  // Zapis (lub usunięcie, gdy null) zdjęcia przez RPC set_avatar.
  Future<void> _saveAvatar(String? b64) async {
    try {
      final res = await _supabase.rpc('set_avatar', params: {'p_url': b64});
      final status = res as String?;
      if (status != null && status != 'ok') {
        final msg = switch (status) {
          'too_large' => 'Zdjęcie za duże — wybierz mniejsze.',
          'not_authenticated' => 'Najpierw się zaloguj.',
          _ => 'Nie udało się ($status).',
        };
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }
      if (mounted) {
        setState(() => _myAvatar = b64);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(b64 == null
                ? 'Zdjęcie usunięte'
                : 'Zdjęcie profilowe zapisane ✨')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Błąd zapisu: $e')));
      }
    }
  }

  // Przypnij widżet z rysunkiem OD tej osoby (kwadrat/pion) na ekran główny.
  Future<void> _pinDrawingWidget(Puszka p) async {
    await pinDrawingWidget(peerId: p.otherId, label: p.label);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Potwierdź przypięcie widżetu 📌 (albo dodaj go z menu ekranu głównego)')));
    }
  }

  // Konfiguracja paska „szybkie czaty": wybór do 5 osób.
  Future<void> _configChatsWidget() async {
    final accepted = _puszki.where((p) => p.status == 'accepted').toList();
    if (accepted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Najpierw dodaj znajomych — z nich budujesz pasek.')));
      return;
    }
    final selected = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        return AlertDialog(
          title: const Text('Widżet: szybkie czaty'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Wybierz osoby (max 5) — ikonka = wejście w czat:'),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: accepted
                        .map((p) => CheckboxListTile(
                              value: selected.contains(p.otherId),
                              title: Text(p.label),
                              onChanged: (v) => setSt(() {
                                if (v == true) {
                                  if (selected.length < 5) {
                                    selected.add(p.otherId);
                                  }
                                } else {
                                  selected.remove(p.otherId);
                                }
                              }),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Anuluj')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Przypnij')),
          ],
        );
      }),
    );
    if (ok != true || selected.isEmpty) return;
    final people = accepted
        .where((p) => selected.contains(p.otherId))
        .map((p) => {'id': p.otherId, 'label': p.label})
        .toList();
    await pinChatsWidget(people);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Potwierdź przypięcie widżetu 📌 (albo dodaj go z menu ekranu głównego)')));
    }
  }

  // Usunięcie konta (wymóg sklepów). Nieodwracalne: RPC kasuje dane + auth.
  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Usunąć konto?'),
        content: const Text(
          'Tej operacji NIE DA SIĘ cofnąć.\n\n'
          'Usuniemy Twoje konto, nazwę, zdjęcie, znajomych i wszystkie '
          'rysunki — wysłane i odebrane.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TC.coral600),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Usuń na zawsze'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _supabase.rpc('delete_account');
      // Konto auth już nie istnieje — czyścimy lokalną sesję (AuthGate wróci
      // na ekran logowania). signOut może rzucić przy nieważnym tokenie.
      try {
        await _supabase.auth.signOut();
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nie udało się usunąć konta: $e')),
        );
      }
    }
  }

  Widget _buildList() {
    final incoming = _puszki
        .where((p) => p.status == 'pending' && !p.requestedByMe)
        .toList();
    final accepted = _puszki.where((p) => p.status == 'accepted').toList();
    final outgoing = _puszki
        .where((p) => p.status == 'pending' && p.requestedByMe)
        .toList();

    if (_puszki.isEmpty && _groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TinCanLogo(width: 96),
              const SizedBox(height: 18),
              Text(
                'Tu nie ma jeszcze puszek',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Dodaj kogoś (➕) po nazwie lub e-mailu\ni pociągnijcie razem za sznurek.',
                textAlign: TextAlign.center,
                style: handStyle(size: 22),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        if (incoming.isNotEmpty) ...[
          _sectionHeader('Zaproszenia'),
          ...incoming.map((p) => ListTile(
                leading: _avatarBox(
                  TC.coral.withValues(alpha: 0.14),
                  const Icon(Icons.mark_email_unread_outlined,
                      color: TC.coral600, size: 22),
                ),
                title: Text(p.label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('chce się z Tobą połączyć'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check_circle,
                          color: Color(0xFF2E9E5B)),
                      tooltip: 'Akceptuj',
                      onPressed: () => _respond(p.connectionId, true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cancel, color: TC.coral600),
                      tooltip: 'Odrzuć',
                      onPressed: () => _respond(p.connectionId, false),
                    ),
                  ],
                ),
              )),
        ],
        if (_groups.isNotEmpty) ...[
          _sectionHeader('Grupy'),
          ..._groups.map((g) => ListTile(
                leading: _avatarBox(
                  TC.brand.withValues(alpha: 0.12),
                  const Icon(Icons.group_outlined, color: TC.brand, size: 22),
                ),
                title: Text(g['name'] as String? ?? 'Grupa',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: Icon(Icons.chevron_right, color: TC.inkSoft),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DrawingScreen(
                      groupId: g['id'] as String,
                      peerLabel: g['name'] as String? ?? 'Grupa',
                    ),
                  ),
                ),
              )),
        ],
        if (accepted.isNotEmpty) _sectionHeader('Puszki'),
        ...accepted.map((p) {
          final hasName =
              p.otherUsername != null && p.otherUsername!.isNotEmpty;
          return ListTile(
            leading: _friendLeading(p.otherAvatar, p.label),
            title: Text(p.label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: hasName ? Text(p.otherEmail) : null,
            trailing: PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: TC.inkSoft),
              onSelected: (v) {
                if (v == 'chat') {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ChatScreen(
                        peerId: p.otherId, peerLabel: p.label),
                  ));
                }
                if (v == 'remove') _removeFriend(p.connectionId, p.label);
                if (v == 'widget_sq') _pinDrawingWidget(p);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'chat',
                  child: ListTile(
                    leading: Icon(Icons.chat_bubble_outline),
                    title: Text('Napisz wiadomość'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (isAndroidApp)
                  const PopupMenuItem(
                    value: 'widget_sq',
                    child: ListTile(
                      leading: Icon(Icons.crop_square),
                      title: Text('Widżet: rysunek'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuItem(
                    value: 'remove', child: Text('Usuń znajomego')),
              ],
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DrawingScreen(
                    peerId: p.otherId,
                    peerLabel: p.label,
                    connectionId: p.connectionId,
                  ),
                ),
              );
            },
          );
        }),
        if (outgoing.isNotEmpty) _sectionHeader('Wysłane'),
        ...outgoing.map((p) => ListTile(
              leading: _avatarBox(
                const Color(0x1FE0932F),
                const Icon(Icons.schedule, color: Color(0xFFCC8A2E), size: 22),
              ),
              title: Text(p.label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('wysłano — oczekuje na akceptację'),
              trailing: IconButton(
                icon: Icon(Icons.close, color: TC.inkSoft),
                tooltip: 'Anuluj zaproszenie',
                onPressed: () => _doRemove(p.connectionId),
              ),
            )),
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 16, 8),
        child: Eyebrow(text),
      );
}
