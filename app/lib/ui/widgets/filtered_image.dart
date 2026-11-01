import 'package:flutter/material.dart';

/// An asset picture drawn through a colour [matrix] as it's painted. A
/// [ColorFiltered] around an [Image] does the same with an offscreen layer,
/// which costs a pass of its own on every frame, for every tile and plate on
/// the screen.
///
/// Fills its box (or [width] by [height]). Keeps showing the last picture
/// while a new [asset] loads.
class FilteredImage extends StatefulWidget {
  const FilteredImage(
    this.asset, {
    super.key,
    this.matrix,
    this.width,
    this.height,
    this.fit = BoxFit.fill,
    this.scale,
    this.centerSlice,
    this.filterQuality = FilterQuality.low,
    this.errorBuilder,
  });

  final String asset;

  /// A 5×4 colour matrix, as for [ColorFilter.matrix]; null draws the picture
  /// as it is.
  final List<double>? matrix;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// The picture's scale, as for [Image.asset] (its resolution-aware variant
  /// when null).
  final double? scale;
  final Rect? centerSlice;
  final FilterQuality filterQuality;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<FilteredImage> createState() => _FilteredImageState();
}

class _FilteredImageState extends State<FilteredImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  (Object, StackTrace?)? _error;
  late final _listener = ImageStreamListener(
    (info, _) {
      if (!mounted) return info.dispose();
      setState(() {
        _info?.dispose();
        _info = info;
        _error = null;
      });
    },
    onError: (e, stack) {
      if (mounted) setState(() => _error = (e, stack));
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(FilteredImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset || oldWidget.scale != widget.scale) _resolve();
  }

  void _resolve() {
    final scale = widget.scale;
    final provider = scale == null ? AssetImage(widget.asset) : ExactAssetImage(widget.asset, scale: scale);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final Widget body;
    if (error != null && widget.errorBuilder != null) {
      body = widget.errorBuilder!(context, error.$1, error.$2);
    } else {
      final matrix = widget.matrix;
      body = CustomPaint(
        size: Size.infinite,
        painter: _FilteredPainter(
          _info,
          matrix == null ? null : ColorFilter.matrix(matrix),
          widget.fit,
          widget.centerSlice,
          widget.filterQuality,
        ),
      );
    }
    return SizedBox(width: widget.width, height: widget.height, child: body);
  }
}

class _FilteredPainter extends CustomPainter {
  _FilteredPainter(this.info, this.filter, this.fit, this.centerSlice, this.filterQuality);

  final ImageInfo? info;
  final ColorFilter? filter;
  final BoxFit fit;
  final Rect? centerSlice;
  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    final info = this.info;
    if (info == null || size.isEmpty) return;
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: info.image,
      scale: info.scale,
      fit: fit,
      centerSlice: centerSlice,
      colorFilter: filter,
      filterQuality: filterQuality,
    );
  }

  @override
  bool shouldRepaint(_FilteredPainter old) =>
      old.info?.image != info?.image ||
      old.info?.scale != info?.scale ||
      old.filter != filter ||
      old.fit != fit ||
      old.centerSlice != centerSlice ||
      old.filterQuality != filterQuality;
}
