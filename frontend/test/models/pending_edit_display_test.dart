// D4 (owner, 2026-11-17): the unsent-edits banner counts in words, and an
// edit's track is named for a person, never by its internal ID.
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/models/pending_edit_display.dart';
import 'package:frontend/models/ui/track_ui.dart';

TrackUI _track({String? title, String? artist}) => TrackUI(
      uuidId: '3f2c9a00-0000-4000-8000-000000000001',
      createdAt: 0,
      lastUpdated: 0,
      title: title,
      artist: artist,
      duration: 1,
      bitrateKbps: null,
      sampleRateHz: null,
      channels: null,
      hasAlbumArt: false,
    );

void main() {
  group('pendingEditsSummary', () {
    test('singular and plural', () {
      expect(pendingEditsSummary(pending: 1, conflicted: 0, rejected: 0),
          '1 edit pending');
      expect(pendingEditsSummary(pending: 2, conflicted: 0, rejected: 0),
          '2 edits pending');
      expect(pendingEditsSummary(pending: 0, conflicted: 1, rejected: 0),
          '1 conflict');
      expect(pendingEditsSummary(pending: 0, conflicted: 2, rejected: 0),
          '2 conflicts');
      expect(pendingEditsSummary(pending: 0, conflicted: 0, rejected: 1),
          '1 rejected');
      expect(pendingEditsSummary(pending: 0, conflicted: 0, rejected: 3),
          '3 rejected');
    });

    test('the parts that are not zero, in order, joined by a bullet', () {
      expect(pendingEditsSummary(pending: 2, conflicted: 1, rejected: 1),
          '2 edits pending • 1 conflict • 1 rejected');
      expect(pendingEditsSummary(pending: 0, conflicted: 2, rejected: 1),
          '2 conflicts • 1 rejected');
      expect(pendingEditsSummary(pending: 1, conflicted: 0, rejected: 2),
          '1 edit pending • 2 rejected');
    });
  });

  group('editTrackName', () {
    test('the track on this device: Title — Artist', () {
      expect(editTrackName(track: _track(title: 'Song', artist: 'Band')),
          'Song — Band');
    });

    test('the track on this device without an artist: its title', () {
      expect(editTrackName(track: _track(title: 'Song')), 'Song');
    });

    test('the track on this device wins over the original values', () {
      expect(
        editTrackName(
          track: _track(title: 'Song', artist: 'Band'),
          originalValuesJson: '{"title":"Before","artist":"Old"}',
        ),
        'Song — Band',
      );
    });

    test('no track on this device: the edit\'s original values', () {
      expect(
        editTrackName(
            originalValuesJson: '{"title":"Before","artist":"Old"}'),
        'Before — Old',
      );
      expect(editTrackName(originalValuesJson: '{"title":"Before"}'),
          'Before');
    });

    test('a track without a title falls back to the original values', () {
      expect(
        editTrackName(
          track: _track(artist: 'Band'),
          originalValuesJson: '{"title":"Before","artist":"Old"}',
        ),
        'Before — Old',
      );
    });

    test('neither: Unknown track, never the ID', () {
      expect(editTrackName(), 'Unknown track');
      expect(editTrackName(track: _track()), 'Unknown track');
      expect(editTrackName(originalValuesJson: '{"genre":"Rock"}'),
          'Unknown track');
      expect(editTrackName(originalValuesJson: '{"title":""}'),
          'Unknown track');
      expect(editTrackName(originalValuesJson: 'not json'), 'Unknown track');
      expect(editTrackName(originalValuesJson: '{"title":7}'),
          'Unknown track');
    });
  });
}
