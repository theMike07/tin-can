import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Szyfrowanie end-to-end wiadomości tekstowych DM (v1.3.0).
///
/// Model 1:1: każdy użytkownik ma parę kluczy **X25519**. Klucz PRYWATNY nigdy
/// nie opuszcza urządzenia (`flutter_secure_storage`, na Androidzie Keystore);
/// klucz PUBLICZNY trafia do `profiles.public_key`. Oboje wyliczają ten sam
/// wspólny sekret (ECDH) -> HKDF-SHA256 -> klucz symetryczny; wiadomości
/// szyfrowane **ChaCha20-Poly1305** (losowy nonce na wiadomość). Serwer widzi
/// tylko szyfrogram — ani treści, ani kluczy.
///
/// Świadome kompromisy (wybór usera): statyczny DH => brak forward secrecy;
/// klucz tylko na urządzeniu => reinstalacja/nowy telefon = utrata odczytu
/// starej zaszyfrowanej historii (nowy klucz nie odszyfruje starego szyfrogramu).
/// Wszystko degraduje się łagodnie: brak klucza -> wysyłamy zwykły tekst.
class E2E {
  static const _storage = FlutterSecureStorage();
  static const _privKeyStore = 'e2e_priv_x25519_seed';

  static final _x = X25519();
  // ChaCha20-Poly1305 (nonce 12 B, mac 16 B). Losowy nonce/wiadomość — przy
  // 96-bitowym nonce ryzyko kolizji dla czatu dwojga jest pomijalne.
  static final _cipher = Chacha20.poly1305Aead();
  static const _nonceLen = 12;
  static const _macLen = 16;

  static SimpleKeyPair? _myKeyPair;
  static String? _myPubB64;
  // Cache kluczy konwersacji: klucz publiczny rozmówcy (b64) -> klucz symetryczny.
  static final Map<String, SecretKey> _convKeys = {};

  /// Wczytuje/generuje parę kluczy i wgrywa klucz publiczny do profilu.
  /// Wołane po zalogowaniu; idempotentne i odporne na błędy (E2E zostaje wtedy
  /// wyłączone -> fallback do zwykłego tekstu).
  static Future<void> ensureKeys() async {
    try {
      await _loadOrCreate();
      await Supabase.instance.client
          .rpc('set_public_key', params: {'p_key': _myPubB64});
    } catch (e) {
      debugPrint('E2E_ENSURE_ERROR: $e');
    }
  }

  static Future<void> _loadOrCreate() async {
    if (_myKeyPair != null) return;
    final stored = await _storage.read(key: _privKeyStore);
    if (stored != null) {
      _myKeyPair = await _x.newKeyPairFromSeed(base64.decode(stored));
    } else {
      _myKeyPair = await _x.newKeyPair();
      final seed = await _myKeyPair!.extractPrivateKeyBytes();
      await _storage.write(key: _privKeyStore, value: base64.encode(seed));
    }
    final pub = await _myKeyPair!.extractPublicKey();
    _myPubB64 = base64.encode(pub.bytes);
  }

  // Klucz symetryczny konwersacji z (mój prywatny, publiczny rozmówcy).
  // Symetryczny: DH(a_priv,b_pub) == DH(b_priv,a_pub) -> oboje mają ten sam.
  static Future<SecretKey?> _convKey(String? peerPubB64) async {
    if (peerPubB64 == null || peerPubB64.isEmpty) return null;
    final cached = _convKeys[peerPubB64];
    if (cached != null) return cached;
    try {
      await _loadOrCreate();
      final peerPub = SimplePublicKey(base64.decode(peerPubB64),
          type: KeyPairType.x25519);
      final shared = await _x.sharedSecretKey(
          keyPair: _myKeyPair!, remotePublicKey: peerPub);
      final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
        secretKey: shared,
        nonce: utf8.encode('tin-can-e2e-v1'),
        info: utf8.encode('dm'),
      );
      _convKeys[peerPubB64] = derived;
      return derived;
    } catch (e) {
      debugPrint('E2E_CONVKEY_ERROR: $e');
      return null;
    }
  }

  /// Szyfruje tekst do rozmówcy. Zwraca base64 (nonce+cipher+mac) albo null,
  /// gdy nie da się zaszyfrować (brak klucza rozmówcy -> wyślij zwykły tekst).
  static Future<String?> encrypt(String text, String? peerPubB64) async {
    final key = await _convKey(peerPubB64);
    if (key == null) return null;
    try {
      final box = await _cipher.encrypt(utf8.encode(text), secretKey: key);
      return base64.encode(box.concatenation());
    } catch (e) {
      debugPrint('E2E_ENC_ERROR: $e');
      return null;
    }
  }

  /// Odszyfrowuje base64 blob. null = nie udało się (np. wiadomość zaszyfrowana
  /// starym kluczem po reinstalacji) -> UI pokazuje kłódkę.
  static Future<String?> decrypt(String blob, String? peerPubB64) async {
    final key = await _convKey(peerPubB64);
    if (key == null) return null;
    try {
      final box = SecretBox.fromConcatenation(base64.decode(blob),
          nonceLength: _nonceLen, macLength: _macLen);
      final clear = await _cipher.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (e) {
      debugPrint('E2E_DEC_ERROR: $e');
      return null;
    }
  }
}
