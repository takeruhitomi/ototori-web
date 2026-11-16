import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Displays the immutable PDF snapshot, independently of the active OMR job.
class ScoreReference extends StatefulWidget {
  const ScoreReference({super.key, required this.hash, required this.page,
    this.layout, this.measures = const [], this.sourceMeasure = 0,
    this.fraction = 0, this.onSeek, this.onPage, this.totalPages = 0});
  final String hash;
  final int page;
  final int totalPages;
  final Map? layout;
  final List<Map> measures;
  final int sourceMeasure;
  final double fraction;
  final void Function(int)? onSeek;
  final void Function(int)? onPage;
  @override
  State<ScoreReference> createState() => _ScoreReferenceState();
}

class _ScoreReferenceState extends State<ScoreReference> {
  static const _channel = MethodChannel('jp.choiromr.mobile/pdf');
  Uint8List? bytes;
  String? error;
  bool busy = true;
  int generation = 0;
  double aspect = 1 / 1.414;
  @override
  void initState() { super.initState(); load(); }
  @override
  void didUpdateWidget(covariant ScoreReference oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hash != widget.hash || oldWidget.page != widget.page) load();
  }

  Future<void> load() async {
    final token = ++generation;
    setState(() { busy = true; bytes = null; error = null; });
    try {
      final image = await _channel.invokeMethod<Uint8List>('renderSourcePage', {'hash': widget.hash, 'page': widget.page - 1});
      if (image == null || image.isEmpty) throw const FormatException('原譜画像がありません。');
      // The PDF adapter returns PNG. Read its IHDR dimensions without decoding
      // a second full bitmap alongside the Image widget.
      var ratio = 1 / 1.414;
      if (image.length >= 24 && image[0] == 137 && image[1] == 80 && image[2] == 78 && image[3] == 71) {
        final header = ByteData.sublistView(image);
        final width = header.getUint32(16), height = header.getUint32(20);
        if (width > 0 && height > 0) ratio = width / height;
      }
      if (mounted && token == generation) setState(() { bytes = image; aspect = ratio; });
    } on PlatformException catch (e) {
      if (mounted && token == generation) setState(() => error = e.message ?? '原譜を表示できませんでした。');
    } on FormatException catch (e) {
      if (mounted && token == generation) setState(() => error = e.message);
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '原譜画像を開けませんでした。');
    } finally {
      if (mounted && token == generation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: PageStorageKey('source-scroll-${widget.hash}-${widget.page}'),
    child: Column(children: [
    Text('原譜 ${widget.page}ページ（音程修正は画像には反映されません）'),
    Wrap(spacing: 4, children: [
      for (final page in ({
        ...widget.measures.map((m) => m['page'] as int? ?? 1),
        for (var i = 1; i <= widget.totalPages; i++) i,
      }.toList()..sort()))
        ChoiceChip(label: Text('$pageページ'), selected: page == widget.page, onSelected: (_) => widget.onPage?.call(page)),
    ]),
    if (busy) const LinearProgressIndicator(),
    if (error != null) ...[Text(error!), TextButton(onPressed: load, child: const Text('原譜を再読み込み'))],
    if (bytes != null) Builder(builder: (context) {
      final pageLayout = (widget.layout?['pages'] as List? ?? []).where((p) => p['page'] == widget.page).firstOrNull as Map?;
      final width = (pageLayout?['width'] as num?)?.toDouble() ?? aspect;
      final height = (pageLayout?['height'] as num?)?.toDouble() ?? 1;
      final systems = (pageLayout?['systems'] as List? ?? []).cast<Map>();
      List<int> indices(Map region) => [for (var i = 0; i < widget.measures.length; i++)
        if ((widget.measures[i]['page'] ?? 1) == widget.page &&
          (widget.measures[i]['system'] == region['index'] ||
            (region['first_measure'] is num && i + 1 >= region['first_measure'] && i + 1 <= region['last_measure']))) i];
      return SizedBox(height: 480, child: InteractiveViewer(minScale: 0.5, maxScale: 8,
        child: Center(child: AspectRatio(aspectRatio: width / height, child: LayoutBuilder(builder: (context, box) =>
          GestureDetector(onTapUp: (details) {
            final point = details.localPosition;
            for (final region in systems) {
              if (point.dy / box.maxHeight < (region['y0'] as num) / height ||
                  point.dy / box.maxHeight > (region['y1'] as num) / height) { continue; }
              final bars = indices(region);
              if (bars.isEmpty) continue;
              final x = ((point.dx / box.maxWidth * width - (region['x0'] as num)) /
                ((region['x1'] as num) - (region['x0'] as num))).clamp(0.0, 0.999999);
              widget.onSeek?.call(bars[(x * bars.length).floor()]);
              return;
            }
          }, child: Stack(fit: StackFit.expand, children: [
            Image.memory(bytes!, fit: BoxFit.fill, gaplessPlayback: false,
              errorBuilder: (context, exception, stackTrace) => const Text('原譜画像を開けませんでした。')),
            for (final region in systems)
              if (indices(region).contains(widget.sourceMeasure)) Builder(builder: (context) {
                final bars = indices(region);
                final x0 = (region['x0'] as num).toDouble(), x1 = (region['x1'] as num).toDouble();
                final barWidth = (x1 - x0) / bars.length;
                return Positioned(left: (x0 + bars.indexOf(widget.sourceMeasure) * barWidth) / width * box.maxWidth,
                  top: (region['y0'] as num) / height * box.maxHeight,
                  width: barWidth / width * box.maxWidth,
                  height: ((region['y1'] as num) - (region['y0'] as num)) / height * box.maxHeight,
                  child: IgnorePointer(child: Container(decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.18), border: Border.all(color: Colors.orange)),
                    child: Align(alignment: Alignment(-1 + widget.fraction.clamp(0, 1) * 2, 0),
                      child: Container(width: 2, color: Colors.red)))));
              }),
          ])))))));
    }),
    if (widget.layout == null) const Text('この楽譜には段の位置情報がありません。ページ選択と拡大で確認できます。'),
    if (widget.layout != null) const Text('段をタップすると原譜の小節へ移動します（小節の横幅は推定）。'),
  ]));
}
