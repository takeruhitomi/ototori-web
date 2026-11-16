/// Bounded repeat and ending expansion for score.json playback.
/// Mirrors choir_omr/repeats.py: source measures remain unchanged.
class RepeatPlan {
  const RepeatPlan(this.order, this.warnings, this.valid);
  final List<int> order;
  final List<String> warnings;
  final bool valid;
}

class _Ending {
  _Ending(this.start, this.end, this.passes);
  int start, end;
  final List<int> passes;
}

class _Region {
  _Region(this.start, this.end, this.times, [List<_Ending>? endings]) : endings = endings ?? [];
  final int start, end, times;
  final List<_Ending> endings;
  int get extent => endings.fold(end, (value, e) => e.end > value ? e.end : value);
}

class RepeatPlanner {
  static const maxPlayedMeasures = 10000;
  List<Map<String, dynamic>> detectedRegions(Map<String, dynamic> score) {
    final staves = score['staves'] as List;
    final count = staves.fold<int>(0, (n, s) => (s['measures'] as List).length > n ? (s['measures'] as List).length : n);
    return [for (final r in _detect(staves, count, [])) {
      'start': r.start, 'end': r.end, 'times': r.times,
      'endings': [for (final e in r.endings) {'start': e.start, 'end': e.end, 'passes': e.passes}],
    }];
  }

  RepeatPlan build(Map<String, dynamic> score) {
    final warnings = <String>[];
    final staves = (score['staves'] as List?) ?? const [];
    final count = staves.fold<int>(0, (value, staff) {
      final length = (staff['measures'] as List).length;
      return length > value ? length : value;
    });
    final natural = List<int>.generate(count, (i) => i);
    try {
      final detected = _detect(staves, count, warnings);
      final meta = score['meta'] is Map ? score['meta'] as Map : const {};
      final enabled = meta['repeats_enabled'] ?? true;
      if (enabled is! bool) throw const FormatException('反復設定が不正です。');
      if (!enabled) return RepeatPlan(natural, warnings, true);
      final override = meta['repeat_override'];
      final regions = _validate(override == null ? detected : _parseRegions(override, count), count);
      final order = <int>[];
      void section(int first, int last, List<_Region> children, int depth, List<_Ending>? endings, int? turn) {
        if (depth > 8) throw const FormatException('反復の入れ子は8段までです。');
        var i = first;
        while (i <= last) {
          if (endings != null && endings.any((e) => e.start <= i && i <= e.end && !e.passes.contains(turn))) { i++; continue; }
          _Region? child;
          for (final region in children) { if (region.start == i) { child = region; break; } }
          if (child != null) {
            final current = child;
            final inner = children.where((r) => !identical(r, current) && current.start <= r.start && r.extent <= current.extent).toList();
            for (var pass = 1; pass <= current.times; pass++) {
              section(current.start, current.extent, inner, depth + 1, current.endings, pass);
            }
            i = current.extent + 1;
          } else {
            if (order.length >= maxPlayedMeasures) throw const FormatException('再生順が10,000小節を超えます。');
            order.add(i - 1); i++;
          }
        }
      }
      section(1, count, regions, 0, null, null);
      return RepeatPlan(order, warnings, true);
    } on FormatException catch (error) {
      return RepeatPlan(natural, [...warnings, '繰り返しを展開できません: ${error.message} 記譜順で再生します。'], false);
    } on TypeError {
      return RepeatPlan(natural, [...warnings, '繰り返しの形式が不正です。記譜順で再生します。'], false);
    }
  }

  List<_Region> _detect(List staves, int size, List<String> warnings) {
    final regions = <_Region>[];
    final stack = <int>[];
    final endings = <_Ending>[];
    var boundary = 1;
    for (var index = 0; index < size; index++) {
      final column = <Map>[];
      for (final staff in staves) {
        final measures = staff['measures'] as List;
        if (index < measures.length) column.add(measures[index] as Map);
      }
      final number = index + 1;
      if (column.any((m) => m['repeat_start'] == true)) stack.add(number);
      final counts = <int, int>{};
      for (final m in column) {
        final end = m['repeat_end'] ?? 0;
        if (end is! int) throw const FormatException('反復回数が不正です。');
        if (end != 0) counts[end] = (counts[end] ?? 0) + 1;
      }
      if (counts.isNotEmpty) {
        if (counts.length > 1) warnings.add('$number小節: パート間で繰り返し回数が異なります。確認してください。');
        var times = counts.keys.first;
        for (final entry in counts.entries) { if (entry.value > counts[times]!) times = entry.key; }
        final start = stack.isNotEmpty ? stack.removeLast() : boundary;
        regions.add(_Region(start, number, times));
        boundary = number + 1;
      }
      final variants = <String>{};
      final passes = <int>{};
      for (final m in column) {
        final raw = m['ending_numbers'] ?? const [];
        if (raw is! List) throw const FormatException('括弧番号が不正です。');
        if (raw.isNotEmpty) {
          final values = raw.map((v) => _integer(v, 1, 8)).toSet().toList()..sort();
          variants.add(values.join(',')); passes.addAll(values);
        }
        final navigation = m['navigation'] ?? const [];
        if (navigation is! List) throw const FormatException('移動記号が不正です。');
        for (final nav in navigation) {
          final message = '$number小節: $nav は自動展開に未対応です。再生順を確認してください。';
          if (!warnings.contains(message)) warnings.add(message);
        }
      }
      if (variants.length > 1) warnings.add('$number小節: パート間で括弧の番号が異なります。確認してください。');
      if (passes.isNotEmpty) {
        final numbers = passes.toList()..sort();
        if (endings.isNotEmpty && endings.last.end == number - 1 && _same(endings.last.passes, numbers)) {
          endings.last.end = number;
        } else { endings.add(_Ending(number, number, numbers)); }
      }
    }
    for (final start in stack) { warnings.add('$start小節: 繰り返しの終点が見つかりません。'); }
    for (final ending in endings) {
      final candidates = regions.where((r) => r.start <= ending.start && ending.start <= r.extent + 1).toList()
        ..sort((a, b) => a.start == b.start ? b.end.compareTo(a.end) : b.start.compareTo(a.start));
      if (candidates.isEmpty) { warnings.add('${ending.start}小節: 括弧に対応する繰り返しが見つかりません。'); }
      else { candidates.first.endings.add(ending); }
    }
    return regions;
  }

  List<_Region> _parseRegions(dynamic value, int size) {
    if (value is! List || value.length > 128) throw const FormatException('反復区間が不正です。');
    return value.map((raw) {
      if (raw is! Map) throw const FormatException('反復区間が不正です。');
      final start = _integer(raw['start'], 1, size);
      final end = _integer(raw['end'], start, size);
      final times = _integer(raw['times'] ?? 2, 2, 8);
      final rawEndings = raw['endings'] ?? const [];
      if (rawEndings is! List || rawEndings.length > 8) throw const FormatException('括弧が不正です。');
      final endings = rawEndings.map((e) {
        if (e is! Map) throw const FormatException('括弧が不正です。');
        final a = _integer(e['start'], start, size);
        final b = _integer(e['end'], a, size);
        final rawPasses = e['passes'];
        if (rawPasses is! List || rawPasses.isEmpty || rawPasses.length > 8) throw const FormatException('括弧の回が不正です。');
        return _Ending(a, b, (rawPasses.map((p) => _integer(p, 1, times)).toSet().toList()..sort()));
      }).toList();
      return _Region(start, end, times, endings);
    }).toList();
  }

  List<_Region> _validate(List<_Region> regions, int size) {
    if (regions.length > 128) throw const FormatException('反復区間が多すぎます。');
    for (final r in regions) {
      _integer(r.start, 1, size); _integer(r.end, r.start, size); _integer(r.times, 2, 8);
      r.endings.sort((a, b) => a.start.compareTo(b.start));
      final used = <int>{};
      for (final e in r.endings) {
        _integer(e.start, r.start, size); _integer(e.end, e.start, size);
        if (e.passes.isEmpty || e.passes.length > 8) throw const FormatException('括弧の回が不正です。');
        for (final pass in e.passes) {
          _integer(pass, 1, r.times);
          if (!used.add(pass)) throw const FormatException('括弧の演奏回が重複しています。');
        }
      }
      if (r.endings.isNotEmpty) {
        if (r.endings.first.start > r.end || r.endings.first.end != r.end || !r.endings.first.passes.contains(1)) {
          throw const FormatException('最初の括弧が反復終点に一致しません。');
        }
        for (var i = 1; i < r.endings.length; i++) {
          if (r.endings[i].start != r.endings[i - 1].end + 1) throw const FormatException('括弧の区間が連続していません。');
        }
      }
    }
    regions.sort((a, b) => a.start == b.start ? b.extent.compareTo(a.extent) : a.start.compareTo(b.start));
    for (var i = 0; i < regions.length; i++) {
      final a = regions[i];
      for (final b in regions.skip(i + 1)) {
        if (b.start > a.extent) break;
        if (b.extent > a.extent || (b.start == a.start && b.extent == a.extent)) {
          throw const FormatException('反復区間が交差または重複しています。');
        }
        if (a.endings.any((e) => b.start <= e.end && b.extent >= e.start)) {
          throw const FormatException('括弧の中の入れ子反復は未対応です。');
        }
      }
    }
    return regions;
  }

  static int _integer(dynamic value, int min, int max) {
    if (value is! int || value < min || value > max) throw const FormatException('反復の数値が範囲外です。');
    return value;
  }
  static bool _same(List<int> a, List<int> b) => a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
}
