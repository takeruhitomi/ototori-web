import 'omr_symbols.dart';

/// The model exposes the denominator; a global median can hide a longer bar.
/// Extend only when a strict majority of physical staves agree exactly.
List<String> inferEnsembleMeters(List<Map<String, dynamic>> staves) {
  final warnings = <String>[];
  if (staves.length < 2) return warnings;
  BeatFraction fraction(dynamic value) {
    final pieces = '$value'.split('/');
    return BeatFraction(int.parse(pieces[0]), pieces.length == 1 ? 1 : int.parse(pieces[1]));
  }
  for (var index = 0; index < (staves.first['measures'] as List).length; index++) {
    final bars = [for (final staff in staves) staff['measures'][index] as Map];
    final time = (bars.first['time_sig'] as List).cast<int>();
    if (bars.any((m) => (m['time_sig'] as List).join('/') != time.join('/'))) continue;
    final nominal = BeatFraction(time[0] * 4, time[1]);
    final votes = <BeatFraction, int>{};
    var voters = 0;
    for (final bar in bars) {
      if ((bar['events'] as List).every((e) => e['inferred_rest'] == true)) continue;
      voters++;
      var end = BeatFraction.zero;
      for (final event in bar['events'] as List) {
        if (event['grace'] == true) continue;
        final stop = fraction(event['onset']) + fraction(event['duration']);
        if (stop.compareTo(end) > 0) end = stop;
      }
      votes[end] = (votes[end] ?? 0) + 1;
    }
    final candidates = votes.entries.where((v) => v.value > voters ~/ 2 && v.key.compareTo(nominal) > 0);
    if (candidates.isEmpty) continue;
    final beats = candidates.single.key;
    final numerator = beats * BeatFraction(time[1], 4);
    if (numerator.denominator != 1 || numerator.numerator > 999) continue;
    for (final bar in bars) { bar['time_sig'] = [numerator.numerator, time[1]]; }
    warnings.add('${index + 1}小節: 複数の五線の音価から${numerator.numerator}/${time[1]}拍子と推定しました。原譜を確認してください。');
  }
  return warnings;
}
