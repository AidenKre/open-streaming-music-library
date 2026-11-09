import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:frontend/models/history_intent.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/history/history_providers.dart';

/// Records accepted click intents as immutable `clicked` history events
/// (Phase 5 §6). Called only from [PlaybackRequests]' accepted branch.
///
/// The event (UUID, acceptance time) is built once, synchronously, when the
/// click is accepted; the binding token is read right after, when the
/// click is recorded (SC-01 rule 4). No binding row then means a reset
/// is under way, and the click is dropped with its store. A
/// failed write never affects playback: the same event waits in a bounded
/// in-memory buffer and is retried with the next click, keeping its UUID.
/// A crash before the durable insert can lose it (stated limitation); a
/// fenced write after a reset is dropped.
class ClickRecorder {
  ClickRecorder({
    required HistoryRepository history,
    required ServerBindingRepository binding,
    required Clock clock,
    String Function()? newEventUuid,
  })  : _history = history,
        _binding = binding,
        _clock = clock,
        _newEventUuid = newEventUuid ?? (() => const Uuid().v4());

  static const maxPending = 50;
  final HistoryRepository _history;
  final ServerBindingRepository _binding;
  final Clock _clock;
  final String Function() _newEventUuid;
  /// Unsaved clicks with the binding each was accepted under.
  final List<({String token, HistoryEventPayload event})> _pending = [];
  bool _flushing = false;

  Future<void> record(HistoryIntent intent) async {
    final event = HistoryEventPayload(
      eventUuid: _newEventUuid(),
      kind: 'clicked',
      entityType: intent.entityType,
      entityRef: intent.entityRef,
      occurredAt: _clock.nowUtcMs(),
    );
    final binding = await _binding.current();
    if (binding == null) return; // no session store to record into
    _pending.add((token: binding.localBindingId, event: event));
    if (_pending.length > maxPending) {
      developer.log('Click buffer full; dropping the oldest unsaved click',
          name: 'ClickRecorder');
      _pending.removeAt(0);
    }
    await _flush();
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final next = _pending.first;
        try {
          await _history.insertLocal(next.token, next.event);
          _pending.remove(next);
        } on BindingFencedException {
          // That binding's store is gone (a reset): drop its clicks only.
          _pending.removeWhere((p) => p.token == next.token);
        } on ArgumentError catch (error) {
          // A payload that can never be valid (as for listens): retrying it
          // would hold back every later click.
          developer.log('Dropping an invalid click', name: 'ClickRecorder',
              error: error);
          _pending.remove(next);
        } catch (error, stackTrace) {
          developer.log('Recording a click failed; it will be retried',
              name: 'ClickRecorder', error: error, stackTrace: stackTrace);
          return;
        }
      }
    } finally {
      _flushing = false;
    }
  }
}

final clickRecorderProvider = Provider<ClickRecorder>(
  (ref) => ClickRecorder(
    history: ref.read(historyRepositoryProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    clock: ref.read(clockProvider),
  ),
);
