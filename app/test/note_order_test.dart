import 'dart:convert';
import 'package:choir_mobile/app/bar_model.dart';
import 'package:choir_mobile/score.dart';
import 'package:flutter_test/flutter_test.dart';

const lines = [100.0, 110.0, 120.0, 130.0, 140.0];

Map<String, dynamic> note(String onset, int pitch, double x) => {'onset': onset, 'duration': '1', 'pitches': [pitch],
  'place': {'x': x, 'heads': [{'pitch': pitch, 'x': x, 'y': 135.0, 'confidence': 1.0, 'snapped': true}]}};

const layout = {'pages': [
  {'page': 1, 'width': 1920, 'height': 2715, 'systems': [{'index': 0, 'x0': 200, 'x1': 600, 'y0': 80, 'y1': 170}]},
]};

ScoreDocument score(List<Map<String, dynamic>> events) => ScoreDocument.parse(jsonEncode({
  'title': 'Order', 'meta': {'layout': layout},
  'staves': [{'id': 'S', 'name': 'Soprano', 'role': 'voice', 'measures': [{
    'number': 1, 'page': 1, 'system': 0, 'time_sig': [4, 4], 'key_fifths': 0, 'clef': 'G',
    'bounds': {'x0': 200.0, 'lines0': lines, 'x1': 600.0, 'lines1': lines, 'snapped0': true, 'snapped1': true},
    'events': events,
  }]}],
}));

void main() {
  List<double> xs(ScoreDocument s) {
    final view = BarView.of(s, layout, 0);
    return [for (var e = 0; e < 4; e++) view.heads(0, e).single.x];
  }

  test('positions in beat order are kept as recognized', () {
    expect(xs(score([note('0', 64, 250), note('1', 64, 330), note('2', 64, 420), note('3', 64, 510)])), [250, 330, 420, 510]);
  });

  test('two notes on one head: the out-of-order one is placed by its beat', () {
    // Beat 2 took beat 1's head (330), as repeated notes did before layout version 4.
    final s = score([note('0', 64, 250), note('1', 64, 330), note('2', 64, 330), note('3', 64, 510)]);
    final view = BarView.of(s, layout, 0);
    final x = xs(s);
    expect(x[0], 250);
    expect(x[3], 510);
    // One of the pair stays; the other moves between its kept neighbours.
    expect(x[1] < x[2], isTrue);
    expect(x.toSet().length, 4);
    final moved = x[1] == 330 ? 2 : 1;
    expect(view.heads(0, moved).single.edited, isTrue);
  });

  test('a note snapped back to an earlier head moves forward', () {
    final x = xs(score([note('0', 64, 250), note('1', 64, 330), note('2', 64, 260), note('3', 64, 510)]));
    expect(x, [250, 330, 420, 510]);
  });

  test('noteMarks draw the corrected x', () {
    final s = score([note('0', 64, 250), note('1', 64, 330), note('2', 64, 260), note('3', 64, 510)]);
    final marks = noteMarks(s, layout)[1]!;
    expect([for (final m in marks) (m.center.dx * 1920).round()], [250, 330, 420, 510]);
  });
}
