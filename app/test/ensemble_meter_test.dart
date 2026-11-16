import 'package:choir_mobile/ensemble_meter.dart';
import 'package:choir_mobile/omr_staff_assembler.dart';
import 'package:choir_mobile/playback_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> staff(String id, int length, {int? denominator, bool grace = false}) => {
  'id': id, 'name': id, 'role': 'voice', 'measures': [
    {'time_sig': [4, denominator ?? 4], 'events': [
      {'onset': '0/1', 'duration': '$length/1', 'pitches': [60], 'voice': 0,
       'slur_starts': ['phrase-$id'], 'slur_stops': <String>[], 'grace': grace},
    ]},
    {'time_sig': [4, 4], 'events': [
      {'onset': '0/1', 'duration': '4/1', 'pitches': [60], 'voice': 0,
       'slur_starts': <String>[], 'slur_stops': ['phrase-$id'], 'grace': false},
    ]},
  ],
};

void main() {
  test('extends a longer consensus bar and preserves the following bar boundary and tie', () {
    final staves = [staff('S1', 5), staff('S2', 5), staff('S3', 4)];
    expect(inferEnsembleMeters(staves), hasLength(1));
    for (final s in staves) {
      expect(s['measures'][0]['time_sig'], [5, 4]);
      expect(s['measures'][1]['time_sig'], [4, 4]);
      OmrStaffAssembler.resolveTies(s);
    }
    expect(staves[0]['measures'][0]['events'][0]['tie_start'], true);
    expect(staves[0]['measures'][1]['events'][0]['tie_stop'], true);
    final timeline = PlaybackTimelineBuilder().build({'staves': staves, 'tempo_bpm': 80});
    expect(timeline.measureStarts, [0.0, 5.0]);
    expect(timeline.totalBeats, 9);
    expect(timeline.notes.singleWhere((n) => n.staffId == 'S1').duration, 9);
  });
  test('does not turn pickups, grace notes, a split vote or one outlier into a new meter', () {
    final short = [staff('S1', 2), staff('S2', 2), staff('S3', 2)];
    expect(inferEnsembleMeters(short), isEmpty);
    final outlier = [staff('S1', 5), staff('S2', 4), staff('S3', 4)];
    expect(inferEnsembleMeters(outlier), isEmpty);
    expect(inferEnsembleMeters([staff('S1', 5), staff('S2', 4)]), isEmpty);
    expect(inferEnsembleMeters([staff('S1', 5, grace: true), staff('S2', 5, grace: true)]), isEmpty);
  });
  test('does not override conflicting recognized denominators or fractional numerators', () {
    expect(inferEnsembleMeters([staff('S1', 5), staff('S2', 5, denominator: 8)]), isEmpty);
    final staves = [staff('S1', 5), staff('S2', 5)];
    for (final s in staves) { s['measures'][0]['events'][0]['duration'] = '13/3'; }
    expect(inferEnsembleMeters(staves), isEmpty);
  });
}
