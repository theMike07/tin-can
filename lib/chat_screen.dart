import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'logo.dart';
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
  static const _reactionSet = ['❤️', '😂', '👍', '😮', '😢'];
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    myId = supabase.auth.currentUser!.id;
    _load();
    _subscribe();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('messages')
          .select('id, sender, recipient, body, created_at')
          .or('and(sender.eq.$myId,recipient.eq.${widget.peerId}),'
              'and(sender.eq.${widget.peerId},recipient.eq.$myId)')
          .order('created_at', ascending: true)
          .limit(500);
      _messages
        ..clear()
        ..addAll((rows as List).cast<Map<String, dynamic>>());
      await _loadReactions();
    } catch (e) {
      debugPrint('TINCAN_CHAT_LOAD_ERROR: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _scrollToEnd();
      }
    }
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
          callback: (payload) {
            final rec = payload.newRecord;
            if (rec['sender'] != widget.peerId) return; // tylko ta rozmowa
            setState(() => _messages.add(Map<String, dynamic>.from(rec)));
            _scrollToEnd();
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
                    child: Text(e, style: const TextStyle(fontSize: 30)),
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
      final inserted = await supabase
          .from('messages')
          .insert({'sender': myId, 'recipient': widget.peerId, 'body': text})
          .select('id, sender, recipient, body, created_at')
          .single();
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
        titleSpacing: 8,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TinCanLogo(width: 24),
            const SizedBox(width: 8),
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
                          itemBuilder: (_, i) => _bubble(_messages[i]),
                        ),
            ),
            _inputBar(),
          ],
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
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: id != null ? () => _openReactionPicker(id) : null,
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
        decoration: BoxDecoration(
          color: mine
              ? TC.brand
              : Color.alphaBlend(Colors.white.withValues(alpha: 0.9), TC.paper),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 5),
            bottomRight: Radius.circular(mine ? 5 : 18),
          ),
          border:
              mine ? null : Border.all(color: TC.ink.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              body,
              style: TextStyle(
                  color: mine ? Colors.white : TC.ink,
                  fontSize: 15,
                  height: 1.25),
            ),
            const SizedBox(height: 2),
            Text(
              time,
              style: TextStyle(
                  fontSize: 10,
                  color: mine ? Colors.white70 : TC.inkSoft),
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
        color: Color.alphaBlend(Colors.white.withValues(alpha: 0.9), TC.paper),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: mine != null
              ? TC.brand.withValues(alpha: 0.55)
              : TC.ink.withValues(alpha: 0.1),
        ),
      ),
      child: Text(reacs.values.join(' '),
          style: const TextStyle(fontSize: 13)),
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
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Napisz wiadomość…',
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.7),
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
