package com.example.frontend

import android.media.MediaCodecList
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Which of the server's codecs this device can decode (Phase 5 review
        // major 1). Read once at startup by CodecSupport.probe.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "osml/codecs")
            .setMethodCallHandler { call, result ->
                if (call.method == "decodableAudioCodecs") {
                    result.success(decodableAudioCodecs())
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun decodableAudioCodecs(): List<String> {
        val decoderTypes = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { !it.isEncoder }
            .flatMap { info -> info.supportedTypes.map { it.lowercase() } }
            .toSet()
        // ExoPlayer parses these containers itself but decodes through the
        // device's MediaCodec decoders. WAV (raw PCM) needs no decoder.
        val codecs = mutableListOf("pcm")
        val mimes = linkedMapOf(
            "mp3" to "audio/mpeg",
            "aac" to "audio/mp4a-latm",
            "alac" to "audio/alac",
            "flac" to "audio/flac",
        )
        for ((codec, mime) in mimes) {
            if (mime in decoderTypes) codecs.add(codec)
        }
        // ExoPlayer's FLAC playback needs the platform FLAC decoder from
        // Android 8.1 (API 27); older versions need an extension this app
        // does not bundle.
        if (Build.VERSION.SDK_INT < 27) codecs.remove("flac")
        return codecs
    }
}
