import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

// Rodziny fontów (spakowane offline w assets/fonts, deklaracja w pubspec).
const String kFontSans = 'Inter';
const String kFontSerif = 'Instrument Serif';
const String kFontMono = 'JetBrains Mono';
const String kFontHand = 'Caveat';

// ---------------------------------------------------------------------------
//  Motyw marki Tin Can — port języka designu ze stron WWW.
//  „warm-tech editorial": papierowe tło e-ink + siatka technologiczna,
//  poświaty marki, szklane karty, serif nagłówki, pigułkowe przyciski,
//  gradient fiolet→koral, akcent odręczny (Caveat).
// ---------------------------------------------------------------------------

class TC {
  // Papier / e-ink
  static const paper = Color(0xFFFBF8F1);
  static const paper2 = Color(0xFFF3ECDD);
  static const ink = Color(0xFF201D2E);
  static const inkSoft = Color(0xFF55506A);

  // Fiolet marki
  static const brand = Color(0xFF6A57E8);
  static const brand600 = Color(0xFF5947D8);
  static const brand700 = Color(0xFF4835BD);
  static const brand100 = Color(0xFFE6E1FB);
  static const brandLite = Color(0xFF8168FF); // jaśniejszy kraniec gradientu

  // Koral
  static const coral = Color(0xFFFF6B6B);
  static const coral600 = Color(0xFFF24D4D);

  // Ciemna scena „kinowa"
  static const night = Color(0xFF14101F);
  static const night2 = Color(0xFF1D1830);

  // Gradient marki (fiolet → koral), jak `.text-gradient`/`.btn-primary`.
  static const brandGradient = LinearGradient(
    begin: Alignment(-0.8, -0.6),
    end: Alignment(0.9, 0.7),
    colors: [brand, coral],
  );
  static const primaryButtonGradient = LinearGradient(
    begin: Alignment(-0.9, -0.6),
    end: Alignment(0.9, 0.8),
    colors: [brand, brandLite],
  );
}

ThemeData buildTinCanTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: TC.brand,
    brightness: Brightness.light,
  ).copyWith(
    primary: TC.brand,
    secondary: TC.coral,
    surface: TC.paper,
    onSurface: TC.ink,
  );

  // Inter dla treści; nagłówki nadpisujemy Instrument Serif niżej.
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final inter = base.textTheme.apply(fontFamily: kFontSans);
  const serif = kFontSerif;

  final text = inter.copyWith(
    displayLarge: inter.displayLarge?.copyWith(fontFamily: serif, color: TC.ink),
    displayMedium:
        inter.displayMedium?.copyWith(fontFamily: serif, color: TC.ink),
    displaySmall:
        inter.displaySmall?.copyWith(fontFamily: serif, color: TC.ink),
    headlineLarge:
        inter.headlineLarge?.copyWith(fontFamily: serif, color: TC.ink),
    headlineMedium:
        inter.headlineMedium?.copyWith(fontFamily: serif, color: TC.ink),
    headlineSmall:
        inter.headlineSmall?.copyWith(fontFamily: serif, color: TC.ink),
    titleLarge: inter.titleLarge?.copyWith(fontFamily: serif, color: TC.ink),
  ).apply(bodyColor: TC.ink, displayColor: TC.ink);

  return base.copyWith(
    scaffoldBackgroundColor: TC.paper,
    textTheme: text,
    canvasColor: TC.paper,
    dividerColor: TC.ink.withValues(alpha: 0.08),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: TC.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: serif,
        fontSize: 26,
        color: TC.ink,
        height: 1.0,
      ),
      iconTheme: const IconThemeData(color: TC.ink),
    ),
    cardTheme: CardThemeData(
      color: Color.alphaBlend(Colors.white.withValues(alpha: 0.68), TC.paper),
      elevation: 0,
      shadowColor: const Color(0x33382D78),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: TC.ink.withValues(alpha: 0.07)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TC.brand,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TC.ink,
        side: BorderSide(color: TC.ink.withValues(alpha: 0.18)),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: TC.brand600),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: TC.brand,
      foregroundColor: Colors.white,
      elevation: 2,
      focusElevation: 2,
      hoverElevation: 4,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.7),
      prefixIconColor: TC.inkSoft,
      labelStyle: const TextStyle(color: TC.inkSoft),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: TC.ink.withValues(alpha: 0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: TC.ink.withValues(alpha: 0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: TC.brand, width: 1.6),
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: TC.brand,
      thumbColor: TC.brand,
      overlayColor: Color(0x226A57E8),
      inactiveTrackColor: TC.brand100,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: TC.ink,
      contentTextStyle: const TextStyle(color: TC.paper),
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: TC.paper,
      surfaceTintColor: Colors.transparent,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: TC.paper,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: TC.paper,
      surfaceTintColor: Colors.transparent,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

// ---------------------------------------------------------------------------
//  Papierowe tło: kolor papieru + siatka technologiczna + ciepłe poświaty
//  (fiolet lewy-góra, koral prawy-góra). Odpowiednik body::before ze strony.
// ---------------------------------------------------------------------------
class PaperBackground extends StatelessWidget {
  final Widget child;
  const PaperBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _PaperPainter()),
        ),
        child,
      ],
    );
  }
}

class _PaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = TC.paper);

    // Poświata fioletowa (lewy górny róg)
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.7, -1.05),
          radius: 1.15,
          colors: [TC.brand.withValues(alpha: 0.16), TC.brand.withValues(alpha: 0.0)],
          stops: const [0.0, 0.62],
        ).createShader(rect),
    );
    // Poświata koralowa (prawy górny róg)
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(1.05, -1.0),
          radius: 1.0,
          colors: [TC.coral.withValues(alpha: 0.12), TC.coral.withValues(alpha: 0.0)],
          stops: const [0.0, 0.55],
        ).createShader(rect),
    );

    // Siatka technologiczna 48px, atrament @ ~4.5%
    final grid = Paint()
      ..color = TC.ink.withValues(alpha: 0.045)
      ..strokeWidth = 1;
    const step = 48.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
//  Szklana karta (jak `.card`): białe-na-papierze tło, włoskowa obwódka,
//  miękki cień, opcjonalnie gradientowa obwódka `.card-glow`.
// ---------------------------------------------------------------------------
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool glow;
  final VoidCallback? onTap;
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.glow = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(22);
    Widget content = Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(Colors.white.withValues(alpha: 0.68), TC.paper),
        borderRadius: radius,
        border: Border.all(color: TC.ink.withValues(alpha: 0.07)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F201D2E),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x33382D78),
            blurRadius: 40,
            offset: Offset(0, 18),
            spreadRadius: -24,
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );

    if (glow) {
      content = Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              TC.brand.withValues(alpha: 0.55),
              TC.coral.withValues(alpha: 0.30),
              Colors.transparent,
            ],
            stops: const [0.0, 0.45, 0.7],
          ),
        ),
        padding: const EdgeInsets.all(1),
        child: content,
      );
    }

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(borderRadius: radius, onTap: onTap, child: content),
      );
    }
    return content;
  }
}

// ---------------------------------------------------------------------------
//  Eyebrow (jak `.eyebrow`): mono, wersaliki, spacja liter + gradientowa kreska.
// ---------------------------------------------------------------------------
class Eyebrow extends StatelessWidget {
  final String text;
  final bool center;
  const Eyebrow(this.text, {super.key, this.center = false});

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontFamily: kFontMono,
        fontSize: 11,
        letterSpacing: 3.0,
        fontWeight: FontWeight.w500,
        color: TC.inkSoft,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!center) ...[
          Container(
            width: 24,
            height: 1.4,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [TC.brand, Colors.transparent],
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        label,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  Tekst z gradientem marki (jak `.text-gradient`).
// ---------------------------------------------------------------------------
class BrandGradientText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  const BrandGradientText(this.text, {super.key, this.style, this.textAlign});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => TC.brandGradient.createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(
        text,
        textAlign: textAlign,
        style: (style ?? const TextStyle()).copyWith(color: Colors.white),
      ),
    );
  }
}

// Font odręczny (Caveat) — do „ludzkich" podpisów, jak font-hand na stronie.
TextStyle handStyle({double size = 22, Color color = TC.inkSoft}) => TextStyle(
      fontFamily: kFontHand,
      fontSize: size,
      color: color,
      fontWeight: FontWeight.w600,
    );

// ---------------------------------------------------------------------------
//  Pigułkowy przycisk główny (jak `.btn-primary`): gradient + poświata.
// ---------------------------------------------------------------------------
class PrimaryPillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  const PrimaryPillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: TC.primaryButtonGradient,
          boxShadow: [
            BoxShadow(
              color: TC.brand.withValues(alpha: 0.55),
              blurRadius: 24,
              offset: const Offset(0, 10),
              spreadRadius: -8,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: enabled ? onPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  else ...[
                    if (icon != null) ...[
                      Icon(icon, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Miękka poświata-kula (jak `.glow`) — do dekoracji pod treścią.
class Glow extends StatelessWidget {
  final Color color;
  final double size;
  final double opacity;
  const Glow(
      {super.key, required this.color, this.size = 320, this.opacity = 0.2});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }
}
