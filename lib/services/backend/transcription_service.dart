import 'dart:async';

import 'package:bluebubbles/database/global/queue_items.dart';
import 'package:bluebubbles/database/io/attachment.dart';
import 'package:bluebubbles/database/io/chat.dart';
import 'package:bluebubbles/database/io/message.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart' hide Response, FormData, MultipartFile;
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';

// ignore: non_constant_identifier_names
TranscriptionService get TranscriptionSvc => GetIt.I<TranscriptionService>();

/// Outcome of a manual [TranscriptionService.transcribeNow] call, used to drive
/// user-facing feedback (snackbars) from the menu action.
enum TranscriptionResult { success, noApiKey, noAudio, failed }

/// Transcribes incoming audio attachments (voice memos) via OpenAI's audio
/// transcription API and replies into the chat with the resulting text.
///
/// Entry point is [maybeTranscribe], called (unawaited) from the incoming
/// message pipeline. It is fully self-contained and best-effort: any failure is
/// logged and swallowed so it can never disrupt message receipt or sending.
class TranscriptionService extends GetxService {
  static const String _tag = "TranscriptionService";

  /// OpenAI's documented hard limit for the transcription endpoint.
  static const int _maxFileBytes = 25 * 1024 * 1024;

  static const String _endpoint = "https://api.openai.com/v1/audio/transcriptions";

  /// A dedicated Dio instance so we never inherit the BlueBubbles server's
  /// base URL, auth GUID, or self-signed-cert adapter when calling OpenAI.
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 5),
    sendTimeout: const Duration(minutes: 5),
  ));

  /// Attachment GUIDs we have already handled, so duplicate/updated-message
  /// deliveries of the same voice memo don't get transcribed (and billed) twice.
  final Set<String> _handledGuids = {};

  /// Inspect a freshly-received [message] and, if it carries an audio
  /// attachment and the feature is enabled, transcribe and reply into [chat].
  ///
  /// Never throws — safe to call unawaited from the message pipeline.
  Future<void> maybeTranscribe(Message message, Chat chat) async {
    try {
      if (!SettingsSvc.settings.enableAudioTranscription.value) return;
      // Never transcribe our own outgoing messages (incl. our own replies).
      if (message.isFromMe ?? false) return;

      final apiKey = SettingsSvc.settings.transcriptionApiKey.value.trim();
      if (apiKey.isEmpty) {
        Logger.warn("Transcription enabled but no OpenAI API key is set; skipping", tag: _tag);
        return;
      }

      final audioAttachments = message.realAttachments
          .where((a) => a.guid != null && (a.mimeStart == "audio"))
          .toList();
      if (audioAttachments.isEmpty) return;

      for (final attachment in audioAttachments) {
        await _transcribeAndReply(attachment, chat, apiKey);
      }
    } catch (ex, stack) {
      // Intentionally broad: this is a best-effort background feature and must
      // never bubble an error into the incoming-message pipeline that called it.
      Logger.error("Unexpected error during transcription", error: ex, trace: stack, tag: _tag);
    }
  }

  /// Manually transcribe every audio attachment on [message] and reply into
  /// [chat], regardless of the enable flag or whether they were auto-handled
  /// already. Returns a [TranscriptionResult] for user-facing feedback.
  Future<TranscriptionResult> transcribeNow(Message message, Chat chat) async {
    try {
      final apiKey = SettingsSvc.settings.transcriptionApiKey.value.trim();
      if (apiKey.isEmpty) return TranscriptionResult.noApiKey;

      final audioAttachments = message.realAttachments
          .where((a) => a.guid != null && (a.mimeStart == "audio"))
          .toList();
      if (audioAttachments.isEmpty) return TranscriptionResult.noAudio;

      bool any = false;
      for (final attachment in audioAttachments) {
        final ok = await _transcribeAndReply(attachment, chat, apiKey, force: true);
        any = any || ok;
      }
      return any ? TranscriptionResult.success : TranscriptionResult.failed;
    } catch (ex, stack) {
      Logger.error("Manual transcription failed", error: ex, trace: stack, tag: _tag);
      return TranscriptionResult.failed;
    }
  }

  /// Returns true if a transcription reply was sent for [attachment].
  /// When [force] is false, attachments already handled this session are skipped.
  Future<bool> _transcribeAndReply(Attachment attachment, Chat chat, String apiKey, {bool force = false}) async {
    final guid = attachment.guid!;
    if (!force && _handledGuids.contains(guid)) return false;
    _handledGuids.add(guid);

    // 1. Ensure the audio file is on disk locally.
    final path = await _ensureDownloaded(attachment);
    if (path == null) return false;

    // 2. Guard against OpenAI's 25 MB limit before we waste an upload.
    final file = File(path);
    final length = await file.length();
    if (length <= 0) {
      Logger.warn("Audio attachment $guid is empty on disk; skipping", tag: _tag);
      return false;
    }
    if (length > _maxFileBytes) {
      Logger.warn(
        "Audio attachment $guid is ${length ~/ (1024 * 1024)}MB, over OpenAI's 25MB limit; skipping",
        tag: _tag,
      );
      return false;
    }

    // 3. Transcribe via OpenAI.
    final transcript = await _callWhisper(file, attachment, apiKey);
    if (transcript == null || transcript.trim().isEmpty) {
      Logger.info("Empty transcript for $guid; not replying", tag: _tag);
      return false;
    }

    // 4. Reply into the chat with the transcription.
    final prefix = SettingsSvc.settings.transcriptionPrefix.value;
    _sendReply(chat, "$prefix${transcript.trim()}");
    Logger.info("Sent transcription reply for $guid (${transcript.length} chars)", tag: _tag);
    return true;
  }

  /// Returns the local path to the downloaded audio, or null if unavailable.
  Future<String?> _ensureDownloaded(Attachment attachment) async {
    try {
      if (attachment.existsOnDisk) return attachment.path;

      Logger.info("Downloading audio attachment ${attachment.guid} for transcription", tag: _tag);
      final response = await HttpSvc.attachment.download(
        attachment.guid!,
        savePath: attachment.path,
      );
      if (response.statusCode != 200) {
        Logger.warn("Download for ${attachment.guid} returned ${response.statusCode}; skipping", tag: _tag);
        return null;
      }

      if (!await attachment.existsOnDiskAsync) {
        Logger.warn("Download for ${attachment.guid} reported success but file is missing; skipping", tag: _tag);
        return null;
      }
      return attachment.path;
    } on DioException catch (ex) {
      Logger.warn("Network error downloading ${attachment.guid}: ${ex.message}", tag: _tag);
      return null;
    } on FileSystemException catch (ex) {
      Logger.warn("Filesystem error reading ${attachment.guid}: ${ex.message}", tag: _tag);
      return null;
    }
  }

  /// Calls OpenAI's transcription endpoint. Returns the text, or null on failure.
  Future<String?> _callWhisper(File file, Attachment attachment, String apiKey) async {
    final model = SettingsSvc.settings.transcriptionModel.value.trim().isEmpty
        ? "whisper-1"
        : SettingsSvc.settings.transcriptionModel.value.trim();
    final filename = attachment.transferName ?? "audio.m4a";

    try {
      final formData = FormData.fromMap({
        "model": model,
        "response_format": "text",
        "file": await MultipartFile.fromFile(file.path, filename: filename),
      });

      final response = await _dio.post(
        _endpoint,
        data: formData,
        options: Options(
          headers: {"Authorization": "Bearer $apiKey"},
          // We request plain text; accept any 2xx without Dio throwing on parse.
          responseType: ResponseType.plain,
        ),
      );

      final data = response.data;
      if (data is String) return data;
      // Defensive: if a future model ignores response_format and returns JSON.
      if (data is Map && data["text"] is String) return data["text"] as String;
      return data?.toString();
    } on DioException catch (ex) {
      final status = ex.response?.statusCode;
      final body = ex.response?.data;
      Logger.error(
        "OpenAI transcription failed (${status ?? 'no response'}): ${body ?? ex.message}",
        tag: _tag,
      );
      return null;
    }
  }

  void _sendReply(Chat chat, String text) {
    final message = Message(
      dateCreated: DateTime.now(),
      handleId: 0,
      text: text,
      hasDdResults: true,
    );
    message.generateTempGuid();

    OutgoingMsgHandler.queue(
      OutgoingMessage(
        chat: chat,
        message: message,
      ),
    );
  }
}
