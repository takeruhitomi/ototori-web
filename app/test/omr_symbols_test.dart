import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

OmrSymbol symbol(String rhythm) => OmrSymbol(rhythm: rhythm, pitch: 'C4', lift: '_', position: 'upper', articulation: '_', slur: '_');

void main() {
  test('all pinned homr note and rest durations match the Python implementation', () {
    final fixture = jsonDecode(File('test/fixtures/homr_durations.json').readAsStringSync()) as Map<String, dynamic>;
    expect(fixture.length, greaterThan(100));
    for (final entry in fixture.entries) {
      expect(symbol(entry.key).duration.toString(), entry.value, reason: entry.key);
    }
  });

  test('chord marker groups the next note without changing later groups', () {
    final groups = groupOmrChords([symbol('note_4'), symbol('chord'), symbol('note_4'), symbol('rest_8')]);
    expect(groups.map((g) => g.length).toList(), [2, 1]);
    expect(groups[1].single.rhythm, 'rest_8');
    expect(() => groupOmrChords([symbol('chord'), symbol('note_4')]), throwsFormatException);
    expect(() => groupOmrChords([symbol('note_4'), symbol('chord')]), throwsFormatException);
  });

  test('multiple-measure rests are not silently converted into a single rest', () {
    expect(() => symbol('rest_3m').duration, throwsFormatException);
  });

  test('model pitch and accidentals become sounding MIDI pitch values', () {
    OmrSymbol note(String pitch, String lift) => OmrSymbol(rhythm: 'note_4', pitch: pitch, lift: lift, position: 'upper', articulation: '_', slur: '_');
    expect(note('C4', '_').midiPitch, 60);
    expect(note('F4', '#').midiPitch, 66);
    expect(note('B3', 'bb').midiPitch, 57);
    expect(note('C4', 'N').midiPitch, 60);
    expect(note('_', '_').midiPitch, isNull);
    expect(() => note('C4', 'bad').midiPitch, throwsFormatException);
  });

  test('chord advance uses its shortest positive duration', () {
    expect(chordAdvance([symbol('note_2'), symbol('note_4')]), BeatFraction(1, 1));
    expect(chordAdvance([symbol('note_8G')]), BeatFraction.zero);
    expect(chordAdvance([symbol('clef_G2')]), BeatFraction.zero);
  });
}
