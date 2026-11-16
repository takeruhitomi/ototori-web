import 'package:choir_mobile/repeat_plan.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> score(int size, {List<dynamic>? regions, bool enabled = true}) => {
  'meta': {'repeats_enabled': enabled, if (regions != null) 'repeat_override': regions},
  'staves': [{'measures': List.generate(size, (_) => <String, dynamic>{'events': <dynamic>[]})}],
};
Map<String, dynamic> region(int start, int end, {int times = 2, List<dynamic> endings = const []}) =>
    {'start': start, 'end': end, 'times': times, 'endings': endings};
Map<String, dynamic> ending(int start, int end, List<int> passes) => {'start': start, 'end': end, 'passes': passes};

void main() {
  final cases = <List<dynamic>>[
    [[region(1, 2)], [0,1,0,1,2,3,4,5]],
    [[region(2, 3), region(5, 6, times: 3)], [0,1,2,1,2,3,4,5,4,5,4,5]],
    [[region(1, 4, endings: [ending(4, 4, [1]), ending(5, 5, [2])])], [0,1,2,3,0,1,2,4,5]],
    [[region(1, 3, endings: [ending(3, 3, [1])])], [0,1,2,0,1,3,4,5]],
    [[region(1, 3, times: 3, endings: [ending(3, 3, [1,2]), ending(4, 4, [3])])], [0,1,2,0,1,2,0,1,3,4,5]],
    [[region(1, 4), region(2, 3)], [0,1,2,1,2,3,0,1,2,1,2,3,4,5]],
  ];
  for (final item in cases) {
    test('expands browser repeat case ${cases.indexOf(item) + 1}', () {
      final plan = RepeatPlanner().build(score(6, regions: item[0] as List));
      expect(plan.valid, isTrue); expect(plan.order, item[1]);
    });
  }

  test('detects an implicit start and ending marks across parts', () {
    final input = score(5);
    final measures = input['staves'][0]['measures'] as List;
    measures[0]['repeat_start'] = true;
    measures[2]['repeat_end'] = 2;
    measures[2]['ending_numbers'] = [1];
    measures[3]['ending_numbers'] = [2];
    expect(RepeatPlanner().build(input).order, [0,1,2,0,1,3,4]);
  });

  test('invalid and excessive repeats fall back to notated order with warning', () {
    final plan = RepeatPlanner().build(score(6, regions: [region(1, 3), region(2, 4)]));
    expect(plan.valid, isFalse); expect(plan.order, [0,1,2,3,4,5]); expect(plan.warnings, isNotEmpty);
    final large = RepeatPlanner().build(score(2000, regions: [region(1, 2000, times: 8)]));
    expect(large.valid, isFalse); expect(large.order.length, 2000);
  });

  test('disabled repeats keep original order', () {
    expect(RepeatPlanner().build(score(6, regions: [region(1, 2)], enabled: false)).order, [0,1,2,3,4,5]);
  });
}
