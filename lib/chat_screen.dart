import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'crypto.dart';
import 'theme.dart';

// Zwykły czat tekstowy (DM 1:1). Szyfrowanie E2E planowane w przyszłości.
class ChatScreen extends StatefulWidget {
  final String peerId;
  final String peerLabel;
  const ChatScreen({super.key, required this.peerId, required this.peerLabel});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final supabase = Supabase.instance.client;
  late final String myId;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  // Reakcje: messageId -> (userId -> emoji). Jedna reakcja na osobę na wiadomość.
  final Map<String, Map<String, String>> _reactions = {};
  // Serce Z selektorem wariantu (FE0F) — bez niego Android renderuje czarny
  // glif tekstowy zamiast czerwonej emotki.
  static const _reactionSet = ['❤️', '😂', '👍', '😮', '😢'];

  // Stare reakcje zapisane bez FE0F naprawiamy przy wyświetlaniu.
  String _fixEmoji(String e) => e == '❤' ? '❤️' : e;

  // Emoji renderujemy Roboto: bundlowany Inter ma WŁASNY czarno-biały glif
  // serca i wygrywa z systemową kolorową emotką. Roboto go nie ma, więc
  // Android sięga po Noto Color Emoji — serce jest czerwone jak wszędzie.
  static const _emojiStyle = TextStyle(fontFamily: 'Roboto', fontSize: 30);
  final _picker = ImagePicker();
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _sending = false;
  bool _uploading = false;
  String? _peerAvatar; // zdjęcie profilowe rozmówcy (base64) do nagłówka
  String? _peerPubKey; // klucz publiczny rozmówcy (E2E); null = szyfrowanie off

  @override
  void initState() {
    super.initState();
    myId = supabase.auth.currentUser!.id;
    _init();
    _subscribe();
  }

  // Najpierw profil rozmówcy (klucz publiczny), potem wiadomości — żeby dało się
  // je od razu odszyfrować. E2E.ensureKeys gwarantuje, że MÓJ klucz publiczny
  // jest na serwerze, więc rozmówca może szyfrować do mnie.
  Future<void> _init() async {
    await E2E.ensureKeys();
    await _loadPeerProfile();
    await _load();
  }

  // Profil rozmówcy: awatar + klucz publiczny. Odporny na brak kolumny/wiersza.
  Future<void> _loadPeerProfile() async {
    try {
      final row = await supabase
          .from('profiles')
          .select()
          .eq('id', widget.peerId)
          .maybeSingle();
      if (mounted && row != null) {
        setState(() {
          _peerAvatar = row['avatar_url'] as String?;
          _peerPubKey = row['public_key'] as String?;
        });
      }
    } catch (_) {}
  }

  // Odszyfrowuje wiadomość „w miejscu": enc -> body (albo znacznik kłódki).
  Future<void> _decryptRow(Map<String, dynamic> m) async {
    final enc = m['enc'] as String?;
    if (enc == null || enc.isEmpty) return; // zwykły tekst / obrazek
    final text = await E2E.decrypt(enc, _peerPubKey);
    if (text != null) {
      m['body'] = text;
    } else {
      m['_locked'] = true; // nie da się odszyfrować (np. po reinstalacji)
    }
  }

  Future<void> _load() async {
    try {
      // select() = wszystkie kolumny; brak read_at (przed migracją) nie wywala.
      final rows = await supabase
          .from('messages')
          .select()
          .or('and(sender.eq.$myId,recipient.eq.${widget.peerId}),'
              'and(sender.eq.${widget.peerId},recipient.eq.$myId)')
          .order('created_at', ascending: true)
          .limit(500);
      final list = (rows as List).cast<Map<String, dynamic>>();
      await Future.wait(list.map(_decryptRow)); // odszyfruj przed pokazaniem
      _messages
        ..clear()
        ..addAll(list);
      await _loadReactions();
      _markRead();
    } catch (e) {
      debugPrint('TINCAN_CHAT_LOAD_ERROR: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _scrollToEnd();
      }
    }
  }

  // Oznacz przychodzące jako przeczytane (czat otwarty = czytam). RPC może
  // jeszcze nie istnieć przed migracją — wtedy cicho pomijamy.
  Future<void> _markRead() async {
    try {
      await supabase
          .rpc('mark_messages_read', params: {'p_peer': widget.peerId});
    } catch (_) {}
  }

  void _subscribe() {
    _channel = supabase
        .channel('messages:$myId:${widget.peerId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient',
            value: myId,
          ),
          callback: (payload) async {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec['sender'] != widget.peerId) return; // tylko ta rozmowa
            await _decryptRow(rec); // odszyfruj zanim pokażesz
            if (!mounted) return;
            setState(() => _messages.add(rec));
            _scrollToEnd();
            _markRead(); // czytam na żywo — od razu ✓ u nadawcy
          },
        )
        // Odczyty moich wiadomości: rozmówca czyta -> UPDATE read_at -> ✓.
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender',
            value: myId,
          ),
          callback: (payload) {
            final rec = payload.newRecord;
            if (rec['recipient'] != widget.peerId) return;
            final i = _messages.indexWhere((m) => m['id'] == rec['id']);
            if (i < 0) return;
            setState(() => _messages[i] = Map<String, dynamic>.from(rec));
          },
        )
        // Reakcje: RLS oddaje tylko reakcje z moich rozmów; filtrujemy po stronie
        // klienta do wiadomości z tego czatu.
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'message_reactions',
          callback: (payload) {
            final isDelete = payload.eventType == PostgresChangeEvent.delete;
            final rec = isDelete ? payload.oldRecord : payload.newRecord;
            final mid = rec['message_id'] as String?;
            final uid = rec['user_id'] as String?;
            if (mid == null || uid == null) return;
            if (!_messages.any((m) => m['id'] == mid)) return;
            setState(() {
              if (isDelete) {
                _reactions[mid]?.remove(uid);
              } else {
                (_reactions[mid] ??= {})[uid] = (rec['emoji'] as String?) ?? '';
              }
            });
          },
        )
        .subscribe();
  }

  Future<void> _loadReactions() async {
    final ids = _messages.map((m) => m['id'] as String).toList();
    if (ids.isEmpty) return;
    try {
      final reacs = await supabase
          .from('message_reactions')
          .select('message_id, user_id, emoji')
          .inFilter('message_id', ids);
      _reactions.clear();
      for (final r in (reacs as List)) {
        final mid = r['message_id'] as String;
        (_reactions[mid] ??= {})[r['user_id'] as String] =
            r['emoji'] as String;
      }
    } catch (e) {
      debugPrint('TINCAN_REACTIONS_LOAD_ERROR: $e');
    }
  }

  // Ustaw / zmień / cofnij (ta sama = cofnięcie) reakcję na wiadomości.
  Future<void> _react(String messageId, String emoji) async {
    final current = _reactions[messageId]?[myId];
    try {
      if (current == emoji) {
        await supabase
            .from('message_reactions')
            .delete()
            .eq('message_id', messageId)
            .eq('user_id', myId);
        setState(() => _reactions[messageId]?.remove(myId));
      } else {
        await supabase.from('message_reactions').upsert(
            {'message_id': messageId, 'user_id': myId, 'emoji': emoji});
        setState(() => (_reactions[messageId] ??= {})[myId] = emoji);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Reakcja nie zadziałała: $e')));
      }
    }
  }

  void _openReactionPicker(String messageId) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final e in _reactionSet)
                InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: () {
                    Navigator.pop(ctx);
                    _react(messageId, e);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(e, style: _emojiStyle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      // E2E: gdy rozmówca ma klucz publiczny — szyfrujemy, body puste.
      // Bez klucza (albo starsza wersja u rozmówcy) — zwykły tekst.
      final enc = await E2E.encrypt(text, _peerPubKey);
      final payload = <String, dynamic>{
        'sender': myId,
        'recipient': widget.peerId,
        'body': enc == null ? text : '',
        'enc': ?enc,
      };
      Map<String, dynamic> inserted;
      try {
        inserted =
            await supabase.from('messages').insert(payload).select().single();
      } on PostgrestException {
        // kolumna enc jeszcze nie istnieje (przed migracją) -> zwykły tekst
        payload
          ..remove('enc')
          ..['body'] = text;
        inserted =
            await supabase.from('messages').insert(payload).select().single();
      }
      inserted['body'] = text; // lokalnie pokazujemy jawny tekst
      _input.clear();
      setState(() => _messages.add(inserted));
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Nie wysłano: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // Wyślij obrazek/GIF z galerii: upload do storage -> wiadomość z image_url.
  Future<void> _pickAndSendImage() async {
    if (_uploading || _sending) return;
    try {
      // Bez maxWidth/imageQuality — nie przekodowujemy (GIF zostaje animowany).
      final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 8 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Plik za duży (max 8 MB).')));
        }
        return;
      }
      setState(() => _uploading = true);
      final ext = file.name.contains('.')
          ? file.name.split('.').last.toLowerCase()
          : 'jpg';
      final contentType = switch (ext) {
        'gif' => 'image/gif',
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      final path = '$myId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await supabase.storage.from('chat-media').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: contentType),
          );
      final url = supabase.storage.from('chat-media').getPublicUrl(path);
      final inserted = await supabase
          .from('messages')
          .insert({
            'sender': myId,
            'recipient': widget.peerId,
            'body': '',
            'image_url': url,
          })
          .select('id, sender, recipient, body, image_url, created_at')
          .single();
      setState(() => _messages.add(inserted));
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Nie wysłano obrazka: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    final ch = _channel;
    if (ch != null) supabase.removeChannel(ch);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        titleSpacing: 8,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _peerAvatarBadge(),
            const SizedBox(width: 9),
            Flexible(
              child: Text(widget.peerLabel, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
      body: PaperBackground(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              'Napiszcie pierwszą wiadomość ✍️',
                              textAlign: TextAlign.center,
                              style: handStyle(size: 24),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) => Column(
                            children: [
                              if (_needsTimeStamp(i)) _timeStamp(_messages[i]),
                              _bubble(_messages[i]),
                            ],
                          ),
                        ),
            ),
            _inputBar(),
          ],
        ),
      ),
    );
  }

  // Kółko profilowe rozmówcy w nagłówku: zdjęcie albo brandowy placeholder z
  // inicjałem. Bardzo subtelna okrągła obwódka — nie zlewa się z tłem.
  Widget _peerAvatarBadge() {
    const d = 32.0;
    final b64 = _peerAvatar;
    Widget inner;
    if (b64 != null && b64.isNotEmpty) {
      try {
        inner = Image.memory(base64Decode(b64),
            width: d, height: d, fit: BoxFit.cover, gaplessPlayback: true);
      } catch (_) {
        inner = _avatarFallback(d);
      }
    } else {
      inner = _avatarFallback(d);
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

  Widget _avatarFallback(double d) {
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
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
    );
  }

  // Wyśrodkowana godzina nad wiadomością, gdy przerwa od poprzedniej > 10 min.
  bool _needsTimeStamp(int i) {
    final t = DateTime.tryParse(_messages[i]['created_at']?.toString() ?? '');
    if (t == null) return false;
    if (i == 0) return true;
    final prev =
        DateTime.tryParse(_messages[i - 1]['created_at']?.toString() ?? '');
    if (prev == null) return false;
    return t.difference(prev).inMinutes >= 10;
  }

  Widget _timeStamp(Map<String, dynamic> m) {
    final t = DateTime.tryParse(m['created_at']?.toString() ?? '')?.toLocal();
    if (t == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hh =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final label = sameDay
        ? hh
        : '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} $hh';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontMono,
            fontSize: 11,
            letterSpacing: 0.6,
            color: TC.inkSoft,
          ),
        ),
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final mine = m['sender'] == myId;
    final body = (m['body'] as String?) ?? '';
    final t = DateTime.tryParse(m['created_at']?.toString() ?? '')?.toLocal();
    final time = t != null
        ? '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
        : '';
    final id = m['id'] as String?;
    final imageUrl = m['image_url'] as String?;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final locked = m['_locked'] == true; // enc, którego nie da się odszyfrować
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: id != null ? () => _openReactionPicker(id) : null,
        // Dwuklik = szybki lajk serduszkiem (ponowny dwuklik cofa).
        onDoubleTap: id != null ? () => _react(id, '❤️') : null,
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: hasImage
            ? const EdgeInsets.all(5)
            : const EdgeInsets.fromLTRB(14, 9, 14, 7),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
        decoration: BoxDecoration(
          // Motyw dymków = kolory logo: moje fioletowe, przychodzące koralowe
          // (pomarańczowy tint czytelny w obu trybach).
          color: mine
              ? TC.brand
              : Color.alphaBlend(
                  TC.coral.withValues(alpha: TC.dark ? 0.30 : 0.16), TC.paper),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 5),
            bottomRight: Radius.circular(mine ? 5 : 18),
          ),
          border: mine
              ? null
              : Border.all(color: TC.coral.withValues(alpha: 0.28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: 340,
                    maxWidth: MediaQuery.of(context).size.width * 0.68,
                  ),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (c, child, prog) => prog == null
                        ? child
                        : const SizedBox(
                            width: 180,
                            height: 180,
                            child: Center(
                                child: CircularProgressIndicator(
                                    strokeWidth: 2)),
                          ),
                    errorBuilder: (c, e, s) => SizedBox(
                      width: 140,
                      height: 100,
                      child: Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: mine ? Colors.white70 : TC.inkSoft),
                      ),
                    ),
                  ),
                ),
              ),
            if (locked)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline,
                      size: 15, color: mine ? Colors.white70 : TC.inkSoft),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      'Nie można odszyfrować na tym urządzeniu',
                      style: TextStyle(
                          fontStyle: FontStyle.italic,
                          fontSize: 13,
                          color: mine ? Colors.white70 : TC.inkSoft),
                    ),
                  ),
                ],
              ),
            if (body.isNotEmpty) ...[
              if (hasImage) const SizedBox(height: 6),
              Padding(
                padding: hasImage
                    ? const EdgeInsets.symmetric(horizontal: 8)
                    : EdgeInsets.zero,
                child: Text(
                  body,
                  style: TextStyle(
                      color: mine ? Colors.white : TC.ink,
                      fontSize: 15,
                      height: 1.25),
                ),
              ),
            ],
            Padding(
              padding: hasImage
                  ? const EdgeInsets.fromLTRB(8, 3, 8, 2)
                  : const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    time,
                    style: TextStyle(
                        fontSize: 10,
                        color: mine ? Colors.white70 : TC.inkSoft),
                  ),
                  // Jeden ptaszek = rozmówca przeczytał.
                  if (mine && m['read_at'] != null) ...const [
                    SizedBox(width: 4),
                    Text('✓',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
            if (id != null) _reactionChip(id),
          ],
        ),
      ),
    );
  }

  // Reakcje pod dymkiem (emoji obecnych reakcji; moja = obwódka fioletowa).
  Widget _reactionChip(String messageId) {
    final reacs = _reactions[messageId];
    if (reacs == null || reacs.isEmpty) return const SizedBox.shrink();
    final mine = reacs[myId];
    return Container(
      margin: const EdgeInsets.only(top: 1, bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: TC.glass,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: mine != null
              ? TC.brand.withValues(alpha: 0.55)
              : TC.ink.withValues(alpha: 0.1),
        ),
      ),
      child: Text(reacs.values.map(_fixEmoji).join(' '),
          style: _emojiStyle.copyWith(fontSize: 13)),
    );
  }

  // Wstawianie emotek do wiadomości — pełna biblioteka, arkusz zostaje otwarty
  // (można wstawić kilka pod rząd).
  void _openEmojiInsert() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SizedBox(
        height: 320,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            _input.text += emoji.emoji;
            _input.selection =
                TextSelection.collapsed(offset: _input.text.length);
          },
          config: Config(
            height: 320,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: TC.paper,
              emojiSizeMax: 26,
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: TC.paper,
              indicatorColor: TC.brand,
              iconColorSelected: TC.brand,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(backgroundColor: TC.paper),
          ),
        ),
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: TC.paper2,
          border: Border(top: BorderSide(color: TC.ink.withValues(alpha: 0.08))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _uploading
                ? const Padding(
                    padding: EdgeInsets.all(11),
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    onPressed: _pickAndSendImage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    tooltip: 'Wyślij obrazek / GIF',
                    color: TC.inkSoft,
                  ),
            IconButton(
              onPressed: _openEmojiInsert,
              icon: const Icon(Icons.emoji_emotions_outlined),
              tooltip: 'Emotki',
              color: TC.inkSoft,
            ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Napisz wiadomość…',
                  filled: true,
                  fillColor: TC.fieldFill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide:
                        BorderSide(color: TC.ink.withValues(alpha: 0.12)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide:
                        BorderSide(color: TC.ink.withValues(alpha: 0.12)),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _sending
                ? const Padding(
                    padding: EdgeInsets.all(11),
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                    style: IconButton.styleFrom(backgroundColor: TC.brand),
                  ),
          ],
        ),
      ),
    );
  }
}
