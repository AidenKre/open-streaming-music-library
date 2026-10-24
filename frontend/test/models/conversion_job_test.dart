import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/conversion_job.dart';

void main() {
  group('ConversionJob.fromJson', () {
    Map<String, dynamic> baseJson({
      String status = 'queued',
      String? errorText,
      int? targetBitrate = 192,
    }) => {
      'job_id': 42,
      'uuid_id': 'abc-123',
      'target_codec': 'aac',
      'target_container': 'm4a',
      'target_bitrate': targetBitrate,
      'status': status,
      'error_text': errorText,
      'created_at': 1000,
      'updated_at': 1000,
    };

    test('parses basic fields', () {
      final job = ConversionJob.fromJson(baseJson());

      expect(job.jobId, 42);
      expect(job.uuidId, 'abc-123');
      expect(job.targetCodec, 'aac');
      expect(job.targetContainer, 'm4a');
      expect(job.targetBitrate, 192);
    });

    test('null target_bitrate parses for lossless targets', () {
      final job = ConversionJob.fromJson(baseJson(targetBitrate: null));
      expect(job.targetBitrate, isNull);
    });

    test('status "queued" -> ConversionQueued, isQueued true', () {
      final job = ConversionJob.fromJson(baseJson(status: 'queued'));
      expect(job.status, isA<ConversionQueued>());
      expect(job.isQueued, isTrue);
      expect(job.isActive, isTrue);
      expect(job.isTerminal, isFalse);
    });

    test('status "running" -> ConversionRunning, isRunning true', () {
      final job = ConversionJob.fromJson(baseJson(status: 'running'));
      expect(job.status, isA<ConversionRunning>());
      expect(job.isRunning, isTrue);
      expect(job.isActive, isTrue);
      expect(job.isTerminal, isFalse);
    });

    test('status "done" -> ConversionDone, isDone true, terminal', () {
      final job = ConversionJob.fromJson(baseJson(status: 'done'));
      expect(job.status, isA<ConversionDone>());
      expect(job.isDone, isTrue);
      expect(job.isTerminal, isTrue);
      expect(job.isActive, isFalse);
    });

    test('status "cancelled" -> ConversionCancelled, terminal', () {
      final job = ConversionJob.fromJson(baseJson(status: 'cancelled'));
      expect(job.status, isA<ConversionCancelled>());
      expect(job.isCancelled, isTrue);
      expect(job.isTerminal, isTrue);
    });

    test('status "failed" carries error_text as message', () {
      final job = ConversionJob.fromJson(
        baseJson(status: 'failed', errorText: 'ffmpeg exploded'),
      );
      expect(job.status, isA<ConversionFailed>());
      expect((job.status as ConversionFailed).message, 'ffmpeg exploded');
      expect(job.isFailed, isTrue);
      expect(job.isTerminal, isTrue);
    });

    test('status "failed" with null error_text falls back to a default message', () {
      final job = ConversionJob.fromJson(baseJson(status: 'failed', errorText: null));
      expect((job.status as ConversionFailed).message, isNotEmpty);
    });

    test('unknown status throws FormatException', () {
      expect(
        () => ConversionJob.fromJson(baseJson(status: 'bogus')),
        throwsFormatException,
      );
    });
  });
}
