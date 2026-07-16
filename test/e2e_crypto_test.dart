import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// Weryfikuje rdzeń E2E (patrz lib/crypto.dart): X25519 -> HKDF-SHA256 ->
// ChaCha20-Poly1305. Klucz konwersacji MUSI być identyczny po obu stronach,
// a szyfrogram od A musi się odszyfrować u B (i odwrotnie).

final _x = X25519();
final _cipher = Chacha20.poly1305Aead();

Future<SecretKey> convKey(SimpleKeyPair mine, SimplePublicKey peerPub) async {
  final shared = await _x.sharedSecretKey(keyPair: mine, remotePublicKey: peerPub);
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: utf8.encode('tin-can-e2e-v1'),
    info: utf8.encode('dm'),
  );
}

Future<String> enc(String text, SecretKey k, {List<int> aad = const []}) async {
  final box = await _cipher.encrypt(utf8.encode(text), secretKey: k, aad: aad);
  return base64.encode(box.concatenation());
}

Future<String> dec(String blob, SecretKey k, {List<int> aad = const []}) async {
  final box = SecretBox.fromConcatenation(base64.decode(blob),
      nonceLength: 12, macLength: 16);
  return utf8.decode(await _cipher.decrypt(box, secretKey: k, aad: aad));
}

void main() {
  test('E2E round-trip + symetria klucza konwersacji', () async {
    final a = await _x.newKeyPair();
    final b = await _x.newKeyPair();
    final aPub = await a.extractPublicKey();
    final bPub = await b.extractPublicKey();

    final keyA = await convKey(a, bPub); // strona A: (A_priv, B_pub)
    final keyB = await convKey(b, aPub); // strona B: (B_priv, A_pub)

    // 1) Oboje wyliczają ten sam klucz symetryczny.
    expect(await keyA.extractBytes(), await keyB.extractBytes());

    // 2) A szyfruje -> B odszyfrowuje.
    const msg = 'Kocham Cię 🥫❤️ zażółć gęślą jaźń';
    expect(await dec(await enc(msg, keyA), keyB), msg);

    // 3) B szyfruje -> A odszyfrowuje (własne wiadomości też widoczne).
    expect(await dec(await enc('drugi kierunek', keyB), keyA), 'drugi kierunek');
  });

  test('AAD wiąże szyfrogram z para nadawca>odbiorca', () async {
    final a = await _x.newKeyPair();
    final b = await _x.newKeyPair();
    final k = await convKey(a, await b.extractPublicKey());
    final aadAB = utf8.encode('A>B');
    final blob = await enc('sekret', k, aad: aadAB);
    // to samo aad -> OK
    expect(await dec(blob, k, aad: aadAB), 'sekret');
    // podmienione aad (np. atakujący zmienił sender/recipient w bazie) -> błąd
    expect(() => dec(blob, k, aad: utf8.encode('B>A')),
        throwsA(isA<Object>()));
  });

  test('Obcy klucz NIE odszyfrowuje (kłódka po reinstalacji)', () async {
    final a = await _x.newKeyPair();
    final b = await _x.newKeyPair();
    final c = await _x.newKeyPair(); // „nowy klucz po reinstalacji"
    final keyAB = await convKey(a, await b.extractPublicKey());
    final keyAC = await convKey(a, await c.extractPublicKey());
    final blob = await enc('sekret', keyAB);
    // inny klucz konwersacji -> decrypt rzuca (MAC się nie zgadza)
    expect(() => dec(blob, keyAC), throwsA(isA<Object>()));
  });
}
