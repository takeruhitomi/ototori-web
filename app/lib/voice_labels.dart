import 'auto_ensemble.dart';
import 'omr_bridge.dart';
import 'score_ir.dart';
import 'score_structure.dart';

/// Voice names from the printed part labels (OCR), used for naming only.
///
/// The ensemble structure (which staves are voices, how many) still comes
/// from the clefs and the image layout. The labels only rename the voice
/// staves, because the clef table cannot tell a tenor in octave treble clef
/// from a soprano (the model reads both as `clef_G2`). A misread label must
/// not break anything, so the labels are used only when every voice staff of
/// one system carries a part name that fits its clef; otherwise a
/// male-choir title (男声合唱) renames treble staves as tenors.
class VoiceNaming {
  const VoiceNaming(this.names, this.types, this.source);
  final List<String> names;
  final List<String> types;
  /// 'labels' or 'male-choir'.
  final String source;
}

const _typeNames = {
  'soprano': 'Soprano', 'alto': 'Alto', 'tenor': 'Tenor', 'baritone': 'Baritone', 'bass': 'Bass',
};
const _roman = ['', 'I', 'II', 'III', 'IV'];

String _base(String clef) => clef.isEmpty ? '' : clef.substring(0, 1);

/// Labels beside (left of) a staff, or a full part name just above it.
List<(String, int)> _staffLabels(RecognizedStaffSymbols staff, List<RecognizedTextLabel> labels) {
  final height = staff.staffHeight < 1 ? 1.0 : staff.staffHeight;
  final left = staff.left ?? staff.crop[0];
  final top = staff.lines.length == 5 ? staff.lines.first : staff.centerY - height / 2;
  final found = <(double, String, int)>[];
  for (final text in labels) {
    final parsed = parsePartLabel(text.text);
    if (parsed == null || parsed.$1 == 'piano') continue;
    final cy = (text.bounds[1] + text.bounds[3]) / 2;
    final beside = text.bounds[2] <= left + height * .65 && (staff.centerY - cy).abs() <= height * .95;
    // Single letters above a staff are rehearsal marks (A, B), not names.
    final above = text.text.trim().length > 2 &&
        text.bounds[0] >= left - height && text.bounds[2] <= left + height * 5 &&
        text.bounds[1] >= top - height * 1.2 && text.bounds[3] <= top + height * .1;
    if (beside || above) found.add((cy, parsed.$1, parsed.$2));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(String, int)>[];
  for (final (_, type, ordinal) in found) {
    if (!out.contains((type, ordinal))) out.add((type, ordinal));
  }
  return out;
}

/// "Tenor I・II" for one type, "Baritone・Bass" for several.
String _name(List<(String, int)> labels) {
  final types = <String>{for (final (t, _) in labels) t}.toList();
  if (types.length == 1) {
    final ordinals = [for (final (_, o) in labels) if (o > 0 && o < _roman.length) o]..sort();
    final name = _typeNames[types.single]!;
    return ordinals.isEmpty ? name : '$name ${ordinals.map((o) => _roman[o]).join('・')}';
  }
  return [for (final t in types) _typeNames[t]!].join('・');
}

bool _fitsClef(String type, String clef) => switch (_base(clef)) {
  'G' => type != 'baritone' && type != 'bass',
  'F' => type != 'soprano' && type != 'alto',
  _ => true,
};

VoiceNaming? _fromLabels(List<RecognizedPageSymbols> pages, List<String> clefs) {
  for (final page in pages) {
    if (page.labels.isEmpty || page.staves.isEmpty) continue;
    final order = List.generate(page.staves.length, (i) => i)
      ..sort((a, b) => page.staves[a].centerY.compareTo(page.staves[b].centerY));
    final staves = [for (final i in order) page.staves[i]];
    final systems = page.systems?.map((s) => s.staves).toList() ?? [List.generate(staves.length, (i) => i)];
    for (final system in systems) {
      final labelled = [
        for (final i in system)
          if (i >= 0 && i < staves.length) _staffLabels(staves[i], page.labels),
      ].where((l) => l.isNotEmpty).toList();
      if (labelled.length != clefs.length) continue;
      var fits = true;
      for (var v = 0; v < clefs.length && fits; v++) {
        fits = labelled[v].every((l) => _fitsClef(l.$1, clefs[v]));
      }
      if (!fits) continue;
      // Staves sharing one part type are numbered top to bottom (Tenor I,
      // Tenor II): OCR often drops or garbles the printed numerals.
      final single = [for (final l in labelled) l.every((x) => x.$1 == l.first.$1) ? l.first.$1 : null];
      final seen = <String, int>{};
      final names = <String>[];
      for (var v = 0; v < labelled.length; v++) {
        final type = single[v];
        if (type == null || single.where((t) => t == type).length < 2) { names.add(_name(labelled[v])); continue; }
        final k = seen[type] = (seen[type] ?? 0) + 1;
        names.add('${_typeNames[type]} ${k < _roman.length ? _roman[k] : '$k'}');
      }
      return VoiceNaming(names, [for (final l in labelled) l.first.$1], 'labels');
    }
  }
  return null;
}

VoiceNaming? _maleChoir(List<RecognizedPageSymbols> pages, List<String> clefs) {
  final male = pages.any((p) => p.labels.any((l) =>
      l.text.contains('男声') || l.text.toLowerCase().contains('male choir') || l.text.toLowerCase().contains('men\'s choir')));
  if (!male || clefs.any((c) => _base(c) != 'G' && _base(c) != 'F')) return null;
  final g = clefs.where((c) => _base(c) == 'G').length;
  final f = clefs.length - g;
  if (g == 0) return null; // all bass clefs: the clef table already names TB/TBB
  final upper = g == 1 ? ['Tenor'] : [for (var i = 1; i <= g; i++) 'Tenor ${i < _roman.length ? _roman[i] : '$i'}'];
  final lower = f == 0 ? <String>[] : f == 1 ? ['Bass'] : f == 2 ? ['Baritone', 'Bass']
      : [for (var i = 1; i <= f; i++) 'Bass ${i < _roman.length ? _roman[i] : '$i'}'];
  var gi = 0, fi = 0;
  final names = [for (final c in clefs) _base(c) == 'G' ? upper[gi++] : lower[fi++]];
  return VoiceNaming(names, [for (final n in names) voiceTypeFor(n)], 'male-choir');
}

/// Names for the voice staves (in score order, with their clefs), or null to
/// keep the clef-based names.
VoiceNaming? voiceNamesFromLabels(List<RecognizedPageSymbols> pages, List<String> clefs) {
  if (clefs.isEmpty) return null;
  return _fromLabels(pages, clefs) ?? _maleChoir(pages, clefs);
}

/// Renames the voice staves of an automatically assembled [score] before
/// post-processing (the tenor octave rule depends on the voice type).
void applyVoiceLabels(Score score, List<RecognizedPageSymbols> pages, List<String> warnings) {
  final voices = [for (final s in score.staves) if (s.role == voiceRole && !s.added) s];
  final naming = voiceNamesFromLabels(pages, [for (final s in voices) s.clef]);
  if (naming != null) _rename(score, voices, naming, warnings);
  nameAddedParts(score, pages, warnings);
}

/// (voice type or '', solo) from a label such as "Ten. solo (or soli)",
/// "Soprano Solo", "ソロ", or null when it names no part.
(String, bool)? parseAddedPartLabel(String text) {
  final lower = text.toLowerCase();
  final solo = RegExp(r'\bsol(?:o|i|oist)\b').hasMatch(lower) || lower.contains('ソロ');
  // Single letters are rehearsal marks (A, B) or lyrics, not part names.
  if (!solo && lower.trim().length <= 2) return null;
  final first = lower.trim().split(RegExp(r'[\s(（]+')).first;
  final part = parsePartLabel(first);
  final type = part != null && part.$1 != 'piano' ? part.$1 : solo ? voiceTypeFor(first) : '';
  if (!solo && type.isEmpty) return null;
  return (type, solo);
}

/// The staff of [page] at (system, index in system), as assembled.
RecognizedStaffSymbols? _staffAt(RecognizedPageSymbols page, int? system, int index) {
  final order = List.generate(page.staves.length, (i) => i)
    ..sort((a, b) => page.staves[a].centerY.compareTo(page.staves[b].centerY));
  final systems = page.systems;
  final members = systems == null || system == null || system >= systems.length
      ? (system == null || system == 0 ? List.generate(order.length, (i) => i) : null)
      : systems[system].staves;
  if (members == null || index < 0 || index >= members.length || members[index] >= order.length) return null;
  return page.staves[order[members[index]]];
}

/// A label for an added part: beside the staff, or above its left end (a
/// solo staff is usually headed "Ten. solo" above the clef, sometimes two
/// staff heights up, above the dynamics).
(String, bool)? _addedLabel(RecognizedStaffSymbols staff, List<RecognizedTextLabel> labels) {
  final height = staff.staffHeight < 1 ? 1.0 : staff.staffHeight;
  final left = staff.left ?? staff.crop[0];
  final top = staff.lines.length == 5 ? staff.lines.first : staff.centerY - height / 2;
  for (final text in labels) {
    final parsed = parseAddedPartLabel(text.text);
    if (parsed == null) continue;
    final cy = (text.bounds[1] + text.bounds[3]) / 2;
    final beside = text.bounds[2] <= left + height * .65 && (staff.centerY - cy).abs() <= height * .95;
    final above = text.bounds[0] >= left - height * 1.5 && text.bounds[0] <= left + height * 3 &&
        text.bounds[1] >= top - height * 2.5 && text.bounds[3] <= top + height * .1;
    if (beside || above) return parsed;
  }
  return null;
}

/// Names the added parts (score meta `added_parts`) from their printed
/// label, else from the choir: in a male choir a treble staff is a tenor
/// (sounding an octave lower), in a female choir it is a soprano.
void nameAddedParts(Score score, List<RecognizedPageSymbols> pages, List<String> warnings) {
  final parts = (score.meta['added_parts'] as List?)?.cast<Map>() ?? const [];
  if (parts.isEmpty) return;
  final voiceTypes = {for (final s in score.staves) if (s.role == voiceRole && !s.added) s.voiceType};
  final male = voiceTypes.isNotEmpty && voiceTypes.every((t) => t == 'tenor' || t == 'baritone' || t == 'bass');
  final female = voiceTypes.isNotEmpty && voiceTypes.every((t) => t == 'soprano' || t == 'alto');
  final named = <String>[];
  for (final part in parts) {
    final staff = score.staves.firstWhere((s) => s.id == part['id'], orElse: () => Staff(id: ''));
    if (staff.id.isEmpty) continue;
    (String, bool)? label;
    for (final at in (part['systems'] as List? ?? const []).cast<Map>()) {
      final page = pages.where((p) => p.pageNumber == at['page']).firstOrNull;
      final source = page == null ? null : _staffAt(page, at['system'] as int?, at['staff'] as int? ?? -1);
      if (source == null) continue;
      label = _addedLabel(source, page!.labels);
      if (label != null) break;
    }
    final base = _base(staff.clef);
    var type = label?.$1 ?? '';
    final fromChoir = type.isEmpty && (male || female);
    if (type.isEmpty && male) type = base == 'F' ? 'bass' : 'tenor';
    if (type.isEmpty && female) type = base == 'F' ? '' : 'soprano';
    final solo = label?.$2 ?? true;
    final typeName = _typeNames[type];
    staff.name = typeName == null ? staff.name : solo ? '$typeName Solo' : typeName;
    staff.voiceType = type;
    staff.octaveShift = type == 'tenor' && base == 'G' ? -1 : 0;
    part['name'] = staff.name;
    part['name_source'] = label?.$1.isNotEmpty == true ? 'labels' : fromChoir ? 'choir' : label != null ? 'labels' : 'default';
    named.add(staff.name);
  }
  if (named.isNotEmpty) warnings.add('途中から加わるパートを追加しました: ${named.join(', ')}。原譜と照合してください。');
}

void _rename(Score score, List<Staff> voices, VoiceNaming naming, List<String> warnings) {
  for (var i = 0; i < voices.length; i++) {
    final staff = voices[i];
    staff.name = naming.names[i];
    staff.voiceType = naming.types[i];
    staff.octaveShift = staff.voiceType == 'tenor' && _base(staff.clef) == 'G' ? -1 : 0;
  }
  score.meta['voice_names'] = naming.names;
  score.meta['ensemble'] = 'custom';
  score.meta['voice_names_source'] = naming.source;
  warnings.add(naming.source == 'labels'
      ? '声部名を譜面の表記から読み取りました: ${naming.names.join(', ')}。'
      : '男声合唱の表記から、ト音記号の声部をテノールとしました。');
}
