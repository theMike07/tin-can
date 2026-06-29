// Testy jednostkowe formatu rysunku (Stroke <-> JSON).
//
// To jest "format", o którym mówiliśmy w planie: to, co serializujemy do bazy,
// musi się odtworzyć 1:1 po drugiej stronie. Tu to pilnujemy.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tin_can/main.dart';

void main() {
  test('Stroke round-trip: toJson -> fromJson odtwarza kreskę', () {
    final original = Stroke(
      points: const [Offset(1, 2), Offset(3.5, 4.25), Offset(10, 20)],
      color: const Color(0xFF112233),
      width: 4.0,
    );

    final restored = Stroke.fromJson(original.toJson());

    expect(restored.points, original.points);
    expect(restored.width, original.width);
    // Porównujemy jako nieprzezroczysty kolor (format trzyma tylko RRGGBB).
    expect(restored.color.toARGB32(), const Color(0xFF112233).toARGB32());
  });

  test('toJson spłaszcza punkty do [dx, dy, dx, dy, ...]', () {
    final json = Stroke(
      points: const [Offset(1, 2), Offset(3, 4)],
      color: Colors.black,
      width: 2.0,
    ).toJson();

    expect(json['points'], [1.0, 2.0, 3.0, 4.0]);
    expect(json['color'], '000000');
    expect(json['width'], 2.0);
  });
}
