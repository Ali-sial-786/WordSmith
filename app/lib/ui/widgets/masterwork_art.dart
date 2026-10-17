import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../engine/masterworks.dart';
import '../theme/palette.dart';

/// A Masterwork drawn as a blueprint: the outline in pale blueprint lines,
/// with every collected piece cast in gold. A finished one is all gold.
class MasterworkArt extends StatelessWidget {
  const MasterworkArt({
    super.key,
    required this.spec,
    required this.collected,
    this.size = 96,
    this.locked = false,
  });

  final MasterworkSpec spec;

  /// Pieces collected towards it (0 to [MasterworkSpec.pieces]).
  final int collected;
  final double size;

  /// Not started yet: a faint silhouette.
  final bool locked;

  /// The grid the art is cut into: pieces are its cells.
  static (int, int) grid(int pieces) => switch (pieces) {
    6 => (3, 2),
    8 => (4, 2),
    10 => (5, 2),
    _ => (4, 3),
  };

  /// The order pieces fill in, scattered like a jigsaw but the same every
  /// time for a given Masterwork.
  static List<int> order(MasterworkSpec spec) {
    final cells = List.generate(spec.pieces, (i) => i);
    var seed = spec.id.codeUnits.fold(7, (a, c) => (a * 31 + c) & 0x7fffffff);
    for (var i = cells.length - 1; i > 0; i--) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final j = seed % (i + 1);
      final t = cells[i];
      cells[i] = cells[j];
      cells[j] = t;
    }
    return cells;
  }

  Widget _art(Color color) => SvgPicture.asset(
    'assets/masterworks/${spec.id}.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    placeholderBuilder: (_) => Icon(Icons.shield_outlined, size: size, color: color),
    errorBuilder: (_, _, _) => Icon(Icons.shield_outlined, size: size, color: color),
  );

  @override
  Widget build(BuildContext context) {
    if (locked) return _art(Palette.steel.withValues(alpha: 0.18));
    final done = collected >= spec.pieces;
    final gold = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFF0B8), Palette.gold, Color(0xFFA9781C)],
      ).createShader(r),
      child: _art(Colors.white),
    );
    if (done) return gold;
    final (cols, rows) = grid(spec.pieces);
    final have = order(spec).take(max(0, collected)).toSet();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          _art(_blueprintLine),
          ClipPath(clipper: _PiecesClipper(cols, rows, have), child: gold),
          CustomPaint(size: Size.square(size), painter: _GridPainter(cols, rows)),
        ],
      ),
    );
  }
}

const _blueprintLine = Color(0x99CFE6FF);

/// Blueprint paper behind a Masterwork in progress.
const blueprintPaper = Color(0xFF173A5E);

class _PiecesClipper extends CustomClipper<Path> {
  _PiecesClipper(this.cols, this.rows, this.cells);

  final int cols;
  final int rows;
  final Set<int> cells;

  @override
  Path getClip(Size size) {
    final w = size.width / cols;
    final h = size.height / rows;
    final path = Path();
    for (final c in cells) {
      path.addRect(Rect.fromLTWH((c % cols) * w, (c ~/ cols) * h, w, h));
    }
    return path;
  }

  @override
  bool shouldReclip(_PiecesClipper old) => old.cells.length != cells.length || old.cols != cols;
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.cols, this.rows);

  final int cols;
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _blueprintLine.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var i = 1; i < cols; i++) {
      final x = size.width * i / cols;
      for (var y = 0.0; y < size.height; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, min(y + 3, size.height)), paint);
      }
    }
    for (var j = 1; j < rows; j++) {
      final y = size.height * j / rows;
      for (var x = 0.0; x < size.width; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(min(x + 3, size.width), y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.cols != cols || old.rows != rows;
}
