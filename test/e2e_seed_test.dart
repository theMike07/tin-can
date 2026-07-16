import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// KRYTYCZNE: seed zapisany z extractPrivateKeyBytes() musi po ponownym
// wczytaniu (newKeyPairFromSeed) odtworzyć TEN SAM klucz publiczny — inaczej
// klucz publiczny zmienia się przy każdym starcie apki i E2E się sypie.
void main() {
  test('seed X25519 odtwarza ten sam klucz publiczny', () async {
    final x = X25519();
    final kp = await x.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    final pub1 = (await kp.extractPublicKey()).bytes;

    // symulacja restartu: odtwórz z zapisanego seeda (base64 round-trip)
    final restored = await x.newKeyPairFromSeed(base64.decode(base64.encode(seed)));
    final pub2 = (await restored.extractPublicKey()).bytes;

    expect(pub2, pub1, reason: 'klucz publiczny musi być stały po restarcie');

    // i wspólny sekret z partnerem też musi być identyczny
    final partner = await x.newKeyPair();
    final partnerPub = await partner.extractPublicKey();
    final s1 = await x.sharedSecretKey(keyPair: kp, remotePublicKey: partnerPub);
    final s2 = await x.sharedSecretKey(
        keyPair: restored, remotePublicKey: partnerPub);
    expect(await s2.extractBytes(), await s1.extractBytes());
  });
}
