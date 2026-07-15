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
        .subscribe();
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
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
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
