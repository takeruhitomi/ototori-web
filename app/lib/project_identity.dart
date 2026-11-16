import 'dart:math';

/// App-private identity metadata; the exchange score format stays unchanged.
class ProjectIdentity {
  ProjectIdentity(Map<String, dynamic> score, [Object? saved]) : _score = score {
    try {
      final meta = saved == null ? null : saved as Map;
      if (meta != null && meta['schema_version'] != 1) {
        throw const FormatException('保存データの版に対応していません。');
      }
      documentId = meta == null ? _nonce() : _validId(meta['document_id']);
      final revision = meta == null ? 0 : meta['revision'];
      if (revision is! int || revision < 0 || revision > maxRevision) {
        throw const FormatException('保存データのリビジョンが不正です。');
      }
      _revision = revision;
      final parts = score['staves'] as List;
      final savedParts = meta == null ? null : meta['parts'] as List;
      if (savedParts != null && savedParts.length != parts.length) _mismatch();
      final seen = <String>{};
      var counter = 0;
      String claim(Object? value, String kind) {
        final id = meta == null ? '$documentId:$kind:${counter++}' : _validId(value);
        if (!seen.add(id)) throw const FormatException('保存データのIDが重複しています。');
        return id;
      }
      for (var s = 0; s < parts.length; s++) {
        final staff = parts[s] as Map;
        final savedStaff = savedParts?[s] as Map?;
        _ids[staff] = claim(savedStaff?['part_id'], 'part');
        final measures = staff['measures'] as List;
        final savedMeasures = savedStaff?['measures'] as List?;
        if (meta != null && (savedMeasures == null || savedMeasures.length != measures.length)) _mismatch();
        for (var m = 0; m < measures.length; m++) {
          final measure = measures[m] as Map;
          final savedMeasure = savedMeasures?[m] as Map?;
          _ids[measure] = claim(savedMeasure?['measure_id'], 'measure');
          _measureLocations[_ids[measure]!] = (staff: s, measure: m);
          final events = measure['events'] as List;
          final savedNotes = savedMeasure?['notes'] as List?;
          if (meta != null && (savedNotes == null || savedNotes.length != events.length)) _mismatch();
          for (var e = 0; e < events.length; e++) {
            final event = events[e] as Map;
            final savedNote = savedNotes?[e] as Map?;
            final id = claim(savedNote?['note_id'], 'note');
            _ids[event] = id;
            final pitches = event['pitches'] as List;
            final savedPitches = savedNote?['pitch_ids'] as List?;
            if (meta != null && (savedPitches == null || savedPitches.length != pitches.length)) _mismatch();
            _pitches[event] = List.generate(pitches.length, (p) => claim(savedPitches?[p], 'pitch'));
            _locations[id] = (staff: s, measure: m, event: e);
          }
        }
      }
    } on TypeError {
      throw const FormatException('保存データのID形式が不正です。');
    }
  }

  static const maxRevision = 0x1fffffffffffff;
  final Map<String, dynamic> _score;
  late final String documentId;
  late int _revision;
  int get revision => _revision;
  final _ids = Map<Map, String>.identity();
  final _pitches = Map<Map, List<String>>.identity();
  final _locations = <String, ({int staff, int measure, int event})>{};
  final _measureLocations = <String, ({int staff, int measure})>{};

  static String _nonce() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
  static String _validId(Object? id) {
    if (id is! String || id.isEmpty || id.length > 128) throw const FormatException('保存データのIDが不正です。');
    return id;
  }
  static Never _mismatch() => throw const FormatException('保存データのIDと楽譜の構成が一致しません。');
  void checkRevision() {
    if (_revision >= maxRevision) throw const FormatException('編集リビジョンの上限に達しました。');
  }
  void advanceRevision() { checkRevision(); _revision++; }
  Map _staff(int s) => (_score['staves'] as List)[s] as Map;
  Map _measure(int s, int m) => (_staff(s)['measures'] as List)[m] as Map;
  Map _event(int s, int m, int e) => (_measure(s, m)['events'] as List)[e] as Map;
  String partId(int s) => _ids[_staff(s)]!;
  String measureId(int s, int m) => _ids[_measure(s, m)]!;
  String noteId(int s, int m, int e) => _ids[_event(s, m, e)]!;
  String pitchId(int s, int m, int e, int p) => _pitches[_event(s, m, e)]![p];

  ({int staff, int measure, int event, int pitch}) locate(Map value) {
    final location = _locations[value['note_id']];
    if (location == null || partId(location.staff) != value['part_id'] ||
        measureId(location.staff, location.measure) != value['measure_id']) {
      _mismatch();
    }
    final pitch = _pitches[_event(location.staff, location.measure, location.event)]!.indexOf(value['pitch_id'] as String);
    if (pitch < 0) _mismatch();
    return (staff: location.staff, measure: location.measure, event: location.event, pitch: pitch);
  }

  List<String> pitchIds(int s, int m, int e) => List.of(_pitches[_event(s, m, e)]!);

  /// A new note or pitch ID that cannot collide with saved ones.
  String newId() => '$documentId:${_nonce()}';

  ({int staff, int measure}) locateMeasure(String partId, String measureId) {
    final location = _measureLocations[measureId];
    if (location == null || this.partId(location.staff) != partId) _mismatch();
    return location;
  }

  /// Replaces a bar's events with [events] carrying the given IDs.
  void replaceEvents(int s, int m, List<Map<String, dynamic>> events, List<String> noteIds, List<List<String>> pitchIds) {
    final list = _measure(s, m)['events'] as List;
    final incoming = noteIds.toSet();
    if (incoming.length != noteIds.length || events.length != noteIds.length || pitchIds.length != noteIds.length) _mismatch();
    for (final id in incoming) {
      final at = _locations[id];
      if (at != null && (at.staff != s || at.measure != m)) _mismatch();
    }
    for (var i = 0; i < events.length; i++) {
      if (pitchIds[i].length != (events[i]['pitches'] as List).length || pitchIds[i].toSet().length != pitchIds[i].length) _mismatch();
    }
    for (final old in list) {
      _locations.remove(_ids.remove(old));
      _pitches.remove(old);
    }
    list..clear()..addAll(events);
    for (var i = 0; i < events.length; i++) {
      _ids[events[i]] = noteIds[i];
      _pitches[events[i]] = pitchIds[i];
      _locations[noteIds[i]] = (staff: s, measure: m, event: i);
    }
  }

  Map<String, dynamic> toJson() => {
    'schema_version': 1, 'document_id': documentId, 'revision': revision,
    'parts': [for (final staff in _score['staves'] as List) {
      'part_id': _ids[staff], 'measures': [for (final measure in staff['measures'] as List) {
        'measure_id': _ids[measure], 'notes': [for (final event in measure['events'] as List) {
          'note_id': _ids[event], 'pitch_ids': List<String>.of(_pitches[event]!),
        }],
      }],
    }],
  };
}
