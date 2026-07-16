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
  ///
  /// `aad` (associated data) jest UWIERZYTELNIANE, ale nie szyfrowane — wiążemy
  /// nim szyfrogram z parą nadawca>odbiorca, więc atakujący z dostępem do bazy
  /// nie przeniesie szyfrogramu do innego wiersza/rozmowy bez wykrycia (MAC).
  static Future<String?> encrypt(String text, String? peerPubB64,
      {List<int> aad = const []}) async {
    final key = await _convKey(peerPubB64);
    if (key == null) return null;
    try {
      final box =
          await _cipher.encrypt(utf8.encode(text), secretKey: key, aad: aad);
      return base64.encode(box.concatenation());
    } catch (e) {
      debugPrint('E2E_ENC_ERROR: $e');
      return null;
    }
  }

  /// Odszyfrowuje base64 blob. null = nie udało się (zły klucz po reinstalacji,
  /// albo naruszone aad/MAC = manipulacja) -> UI pokazuje kłódkę.
  static Future<String?> decrypt(String blob, String? peerPubB64,
      {List<int> aad = const []}) async {
    final key = await _convKey(peerPubB64);
    if (key == null) return null;
    try {
      final box = SecretBox.fromConcatenation(base64.decode(blob),
          nonceLength: _nonceLen, macLength: _macLen);
      final clear = await _cipher.decrypt(box, secretKey: key, aad: aad);
      return utf8.decode(clear);
    } catch (e) {
      debugPrint('E2E_DEC_ERROR: $e');
      return null;
    }
  }

  // --- Ochrona przed MITM / podmianą klucza na serwerze ---------------------

  /// TOFU (trust-on-first-use): pamięta ostatnio widziany klucz publiczny
  /// rozmówcy. Zwraca true, gdy klucz się ZMIENIŁ względem zapamiętanego
  /// (reinstalacja rozmówcy albo — groźniejsze — podmiana przez serwer/MITM).
  /// Pierwszy raz (brak zapisu) = zapamiętaj po cichu, bez ostrzeżenia.
  static Future<bool> peerKeyChanged(String peerId, String? pubB64) async {
    if (pubB64 == null || pubB64.isEmpty) return false;
    try {
      final prev = await _storage.read(key: 'peerkey_$peerId');
      if (prev == null) {
        await _storage.write(key: 'peerkey_$peerId', value: pubB64);
        return false;
      }
      return prev != pubB64;
    } catch (_) {
      return false;
    }
  }

  /// Zaakceptuj nowy klucz rozmówcy (po świadomym potwierdzeniu, że to była
  /// reinstalacja, a nie atak) — od teraz jest traktowany jako zaufany.
  static Future<void> trustPeerKey(String peerId, String? pubB64) async {
    if (pubB64 == null || pubB64.isEmpty) return;
    try {
      await _storage.write(key: 'peerkey_$peerId', value: pubB64);
    } catch (_) {}
  }

  /// „Numer bezpieczeństwa" — wspólny odcisk obu kluczy publicznych. Oboje
  /// wyliczają ten sam (klucze sortowane), więc porównanie go poza apką (np. na
  /// żywo/telefonicznie) wykrywa MITM: różny numer => ktoś jest w środku.
  static Future<String?> safetyNumber(String? peerPubB64) async {
    if (peerPubB64 == null || peerPubB64.isEmpty) return null;
    try {
      await _loadOrCreate();
      if (_myPubB64 == null) return null;
      final keys = [_myPubB64!, peerPubB64]..sort();
      final digest =
          await Sha256().hash(utf8.encode('tin-can-sn-v1|${keys.join('|')}'));
      final b = digest.bytes;
      // 12 grup po 5 cyfr z 24 bajtów skrótu (2 bajty -> 0..65535 -> 5 cyfr).
      final groups = <String>[];
      for (var i = 0; i < 24; i += 2) {
        final n = (b[i] << 8) | b[i + 1];
        groups.add(n.toString().padLeft(5, '0'));
      }
      return groups.join(' ');
    } catch (e) {
      debugPrint('E2E_SN_ERROR: $e');
      return null;
    }
  }
}
