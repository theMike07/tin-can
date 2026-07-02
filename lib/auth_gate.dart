import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart';
import 'push.dart';

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
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '🥫 Tin Can',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _isRegister ? 'Załóż konto' : 'Zaloguj się',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'E-mail',
                    border: OutlineInputBorder(),
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
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                if (_info != null) ...[
                  const SizedBox(height: 12),
                  Text(_info!, style: const TextStyle(color: Colors.green)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isRegister ? 'Zarejestruj się' : 'Zaloguj się'),
                  ),
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
                const SizedBox(height: 8),
                Row(
                  children: const [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('albo'),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _google,
                  icon: const Icon(Icons.g_mobiledata, size: 28),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text('Kontynuuj z Google'),
                  ),
                ),
              ],
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
  final String status; // 'pending' | 'accepted'
  final bool requestedByMe; // czy JA wysłałem zaproszenie
  Puszka({
    required this.connectionId,
    required this.otherId,
    required this.otherEmail,
    required this.otherUsername,
    required this.status,
    required this.requestedByMe,
  });

  // Tytuł puszki: @nazwa jeśli jest, inaczej e-mail.
  String get label => (otherUsername != null && otherUsername!.isNotEmpty)
      ? '@$otherUsername'
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
  List<Puszka> _puszki = [];

  @override
  void initState() {
    super.initState();
    _load();
    registerPushToken(); // zarejestruj urządzenie do powiadomień push
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = _supabase.auth.currentUser!.id;

      // moja nazwa użytkownika
      final myProfile = await _supabase
          .from('profiles')
          .select('username')
          .eq('id', me)
          .maybeSingle();
      _myUsername = myProfile?['username'] as String?;

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
            .select('id, email, username')
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
          status: (c['status'] as String?) ?? 'accepted',
          requestedByMe: c['requested_by'] == me,
        );
      }).toList();

      if (mounted) {
        setState(() {
          _puszki = puszki;
          _loading = false;
        });
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
            prefixText: '@',
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
        'ok' => 'Nazwa ustawiona: @${value.trim()}',
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
        title: const Text('Twoje puszki'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Odśwież',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Wyloguj',
            onPressed: () => _supabase.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addByEmail,
        icon: const Icon(Icons.add),
        label: const Text('Dodaj'),
      ),
      body: _loading
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
                    Card(
                      margin: const EdgeInsets.all(12),
                      child: ListTile(
                        leading:
                            const Text('🥫', style: TextStyle(fontSize: 28)),
                        title: Text(
                          _myUsername != null && _myUsername!.isNotEmpty
                              ? '@$_myUsername'
                              : 'Ustaw nazwę użytkownika',
                        ),
                        subtitle: Text(user?.email ?? '—'),
                        trailing: TextButton.icon(
                          onPressed: _editUsername,
                          icon: const Icon(Icons.edit, size: 18),
                          label: Text(
                            _myUsername == null || _myUsername!.isEmpty
                                ? 'Ustaw'
                                : 'Zmień',
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _buildList()),
                  ],
                ),
    );
  }

  Widget _buildList() {
    final incoming = _puszki
        .where((p) => p.status == 'pending' && !p.requestedByMe)
        .toList();
    final accepted = _puszki.where((p) => p.status == 'accepted').toList();
    final outgoing = _puszki
        .where((p) => p.status == 'pending' && p.requestedByMe)
        .toList();

    if (_puszki.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Brak puszek.\nDodaj kogoś (➕) po nazwie lub e-mailu. 🥫',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      children: [
        if (incoming.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('📨 Zaproszenia',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...incoming.map((p) => ListTile(
                leading: const Text('📨', style: TextStyle(fontSize: 26)),
                title: Text(p.label),
                subtitle: const Text('chce się z Tobą połączyć'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check_circle, color: Colors.green),
                      tooltip: 'Akceptuj',
                      onPressed: () => _respond(p.connectionId, true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cancel, color: Colors.red),
                      tooltip: 'Odrzuć',
                      onPressed: () => _respond(p.connectionId, false),
                    ),
                  ],
                ),
              )),
          const Divider(),
        ],
        ...accepted.map((p) {
          final hasName =
              p.otherUsername != null && p.otherUsername!.isNotEmpty;
          return ListTile(
            leading: const Text('🥫', style: TextStyle(fontSize: 28)),
            title: Text(p.label),
            subtitle: hasName ? Text(p.otherEmail) : null,
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'remove') _removeFriend(p.connectionId, p.label);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'remove', child: Text('Usuń znajomego')),
              ],
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DrawingScreen(
                    peerId: p.otherId,
                    peerLabel: p.label,
                  ),
                ),
              );
            },
          );
        }),
        ...outgoing.map((p) => ListTile(
              leading: const Text('⏳', style: TextStyle(fontSize: 24)),
              title: Text(p.label),
              subtitle: const Text('wysłano — oczekuje na akceptację'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Anuluj zaproszenie',
                onPressed: () => _doRemove(p.connectionId),
              ),
            )),
      ],
    );
  }
}
