import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/shared/me/me_groups.dart';

void main() {
  const origin = 'https://buzz.block.builderlab.xyz';
  const channel = '11111111-1111-4111-8111-111111111111';
  Map<String, dynamic> record() => {
    'version': 1,
    'community': origin,
    'deleted': false,
    'value': {
      'type': 'groups',
      'id': 'me',
      'groups': [
        {
          'id': 'project-one',
          'name': 'Mobile',
          'defaultTemplateId': 'me-section-one',
        },
      ],
      'assignments': {channel: 'project-one'},
      'channels': [channel],
    },
  };
  test('reads desktop groups and preserves defaults when placing a chat', () {
    final source = record();
    final groups = MeGroups.decode(jsonEncode(source), origin);
    expect(groups.groups.single['defaultTemplateId'], 'me-section-one');
    expect(jsonDecode(groups.place(channel).encode(origin)), source);
    expect(
      MeGroups.coordinate(origin),
      'buzz-me-kit-v1:https%3A%2F%2Fbuzz.block.builderlab.xyz:groups:me',
    );
  });
  test('labelled unfiled chats do not grow the bounded legacy record', () {
    final original = MeGroups.decode(jsonEncode(record()), origin);
    var groups = original;
    for (var i = 0; i < 2000; i++) {
      groups = groups.place(
        '${i.toRadixString(16).padLeft(8, '0')}-2222-4222-8222-222222222222',
        labelled: true,
      );
    }
    expect(groups.encode(origin), original.encode(origin));
    const fresh = '22222222-2222-4222-8222-222222222222';
    final filed = groups.place(fresh, group: 'project-one', labelled: true);
    expect(filed.assignments[fresh], 'project-one');
    expect(filed.channels, [channel]);
    expect(MeGroups.decode(filed.encode(origin), origin).channels, [channel]);
    expect(groups.place(fresh).channels, [channel, fresh]);
    expect(
      () => groups.place(fresh, group: 'missing', labelled: true),
      throwsStateError,
    );
  });
  test('rejects another community and independent Messages organization', () {
    expect(
      () => MeGroups.decode(jsonEncode(record()), 'https://other.test'),
      throwsFormatException,
    );
    final source = record();
    (source['value'] as Map)['id'] = 'messages';
    expect(
      () => MeGroups.decode(jsonEncode(source), origin),
      throwsFormatException,
    );
  });
  test(
    'tombstones clear personal placement without inferring old sessions',
    () {
      final source = record()..['deleted'] = true;
      expect(MeGroups.decode(jsonEncode(source), origin).channels, isEmpty);
    },
  );
  test('rejects duplicate placement and missing project references', () {
    final source = record();
    (source['value'] as Map)['channels'] = [channel, channel];
    expect(
      () => MeGroups.decode(jsonEncode(source), origin),
      throwsFormatException,
    );
    (source['value'] as Map)['channels'] = [channel];
    (source['value'] as Map)['assignments'] = {channel: 'gone'};
    expect(
      () => MeGroups.decode(jsonEncode(source), origin),
      throwsFormatException,
    );
  });
  test('project names use the editors grapheme limit', () {
    for (final character in ['🌳', '👨‍👩‍👧‍👦', 'e\u0301']) {
      MeGroups groups(int count) => MeGroups(
        groups: [
          {'id': 'project', 'name': character * count, 'defaultTemplateId': ''},
        ],
      );
      final encoded = groups(120).encode(origin);
      expect(
        MeGroups.decode(encoded, origin).groups.single['name'],
        character * 120,
      );
      expect(() => groups(121).encode(origin), throwsFormatException);
    }
  });
  test('capacity is measured in UTF-8 bytes before publishing', () {
    final groups = MeGroups(
      groups: List.generate(
        100,
        (i) => {'id': 'g$i', 'name': '🌳' * 60, 'defaultTemplateId': ''},
      ),
    );
    expect(() => groups.encode(origin), throwsFormatException);
  });
}
