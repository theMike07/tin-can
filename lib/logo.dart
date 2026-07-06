import 'package:flutter/material.dart';

/// Znak marki Tin Can: dwie puszki + „sznurek" z DOKŁADNIE 3 kropek.
/// Wierne odwzorowanie z `tin_can_web/src/components/Logo.astro`
/// (viewBox 0 0 40 28). Rysowane wektorowo — ostre przy każdym rozmiarze.
class TinCanLogo extends StatelessWidget {
  final double width;
  final Color canA; // puszka lewa (fioletowa)
  final Color canB; // puszka prawa (koralowa)
  final Color dot; // kolor kropek „sznurka"

  const TinCanLogo({
    super.key,
    this.width = 120,
    this.canA = const Color(0xFF6A57E8),
    this.canB = const Color(0xFFFF6B6B),
    this.dot = const Color(0xFF201D2E),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width * 28 / 40, // proporcje viewBox
      child: CustomPaint(
        painter: _MarkPainter(canA: canA, canB: canB, dot: dot),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final Color canA, canB, dot;
  _MarkPainter({required this.canA, required this.canB, required this.dot});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 40; // skala z viewBox (40 j.) do szerokości widgetu
    final rad = Radius.circular(2.5 * s);
    Paint canPaint(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * s
      ..strokeJoin = StrokeJoin.round
      ..color = c;

    // puszka lewa (fiolet): rect x2 y8 w11 h16
    canvas.drawRRect(
      RRect.fromLTRBR(2 * s, 8 * s, 13 * s, 24 * s, rad),
      canPaint(canA),
    );
    // puszka prawa (koral): rect x27 y4 w11 h16
    canvas.drawRRect(
      RRect.fromLTRBR(27 * s, 4 * s, 38 * s, 20 * s, rad),
      canPaint(canB),
    );

    // 3 kropki „sznurka" (od dolnej lewej ku górnej prawej)
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = dot;
    const dots = [
      Offset(16.6, 15.2),
      Offset(20.0, 12.75),
      Offset(23.4, 9.9),
    ];
    for (final d in dots) {
      canvas.drawCircle(Offset(d.dx * s, d.dy * s), 1.15 * s, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.canA != canA || old.canB != canB || old.dot != dot;
}
