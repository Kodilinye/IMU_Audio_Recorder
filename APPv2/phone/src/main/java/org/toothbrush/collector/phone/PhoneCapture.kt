package org.toothbrush.collector.phone

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.AudioStats
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import org.json.JSONArray
import org.json.JSONObject
import org.toothbrush.collector.core.SessionSpec
import org.toothbrush.collector.shared.Capture
import java.io.File
import java.util.concurrent.Executors

/** CameraX owns the encoded MP4. Stop completes only after its finalization event. */
class PhoneCapture(private val context: Context) : Capture {
    private enum class Phase { IDLE, SETUP, STARTING, RECORDING, STOPPING }

    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private var phase = Phase.IDLE
    private var generation = 0L
    private var provider: ProcessCameraProvider? = null
    private var recording: Recording? = null
    private var boundUseCases = emptyList<UseCase>()
    private var stopRequested = false
    private var videoMetadata: JSONObject? = null
    private var reservedOutput: File? = null
    private var lastAudioState: Int? = null
    private val stopCallbacks = mutableListOf<() -> Unit>()

    @SuppressLint("MissingPermission") // CAMERA and conditional RECORD_AUDIO are checked before use.
    override fun start(
        directory: File,
        session: SessionSpec,
        metadata: JSONObject,
        onStarted: () -> Unit,
        onFailure: (String) -> Unit
    ) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (phase != Phase.IDLE) {
            onFailure("Phone camera is still busy finalizing the previous recording")
            return
        }
        val owner = context as? LifecycleOwner
        if (owner == null || !hasPermission(Manifest.permission.CAMERA)) {
            val reason = "Phone video unavailable: camera permission or lifecycle missing"
            metadata.put("phone_video", JSONObject().put("state", "failed").put("failure", reason))
            metadata.put("phone_video_present", false).put("phone_audio_present", false)
            onFailure(reason)
            return
        }
        val token = ++generation
        phase = Phase.SETUP
        stopRequested = false
        lastAudioState = null
        val video = JSONObject()
            .put("state", "preparing")
            .put("camera_facing", "front")
            .put("container", "MP4")
            .put("quality_preference", JSONArray(listOf("HD", "FHD", "SD")))
            .put("target_rotation", "Surface.ROTATION_0 (natural device orientation)")
            .put("setup_requested_epoch_ms", System.currentTimeMillis())
            .put("setup_requested_elapsed_ns", SystemClock.elapsedRealtimeNanos())
            .put("synchronization_note", "Start callback is an observation, not first-frame exposure time")
        videoMetadata = video
        metadata.put("phone_video", video)
        metadata.put("phone_video_present", false)
        metadata.put("phone_audio_present", false)
        val output = File(directory, "video_${session.stem}.mp4")
        try {
            check(directory.isDirectory || directory.mkdirs()) { "Cannot create phone session directory" }
            check(output.createNewFile()) { "Refusing to overwrite ${output.name}" }
            reservedOutput = output
            video.put("file", output.name)
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                // Cancellation invalidates the setup token before an asynchronous camera bind.
                if (generation != token || phase != Phase.SETUP) return@addListener
                try {
                    val cameraProvider = future.get()
                    provider = cameraProvider
                    check(cameraProvider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)) {
                        "Front camera unavailable; phone video was not recorded"
                    }
                    val recorder = Recorder.Builder().setQualitySelector(
                        QualitySelector.fromOrderedList(
                            listOf(Quality.HD, Quality.FHD, Quality.SD),
                            FallbackStrategy.lowerQualityOrHigherThan(Quality.HD)
                        )
                    ).build()
                    val capture = VideoCapture.withOutput(recorder).apply { targetRotation = Surface.ROTATION_0 }
                    val preview = Preview.Builder().setTargetRotation(Surface.ROTATION_0).build()
                    preview.setSurfaceProvider(previewSurfaceProvider)
                    // A Preview with no surface must not delay the Recorder. Bind only when visible.
                    boundUseCases = if (previewSurfaceProvider != null) listOf(capture, preview) else listOf(capture)
                    activePreview = if (preview in boundUseCases) preview else null
                    cameraProvider.bindToLifecycle(owner, CameraSelector.DEFAULT_FRONT_CAMERA, *boundUseCases.toTypedArray())
                    val audioEnabled = hasPermission(Manifest.permission.RECORD_AUDIO)
                    video.put("audio_requested", audioEnabled)
                    if (!audioEnabled) video.put("audio_absence_reason", "Phone microphone permission not granted; video-only")
                    var pending = recorder.prepareRecording(context, FileOutputOptions.Builder(output).build())
                    if (audioEnabled) pending = pending.withAudioEnabled()
                    phase = Phase.STARTING
                    video.put("record_request_epoch_ms", System.currentTimeMillis())
                    video.put("record_request_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                    recording = pending.start(mainExecutor) recordEvent@{ event ->
                        if (generation != token) return@recordEvent
                        when (event) {
                            is VideoRecordEvent.Start -> {
                                video.put("start_callback_epoch_ms", System.currentTimeMillis())
                                video.put("start_callback_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                                if (!stopRequested) {
                                    phase = Phase.RECORDING
                                    video.put("state", "recording")
                                    metadata.put("phone_video_present", true)
                                    metadata.put("phone_audio_present", audioEnabled)
                                    onStarted()
                                }
                            }
                            is VideoRecordEvent.Status -> {
                                video.put("encoded_duration_ns", event.recordingStats.recordedDurationNanos)
                                video.put("encoded_bytes", event.recordingStats.numBytesRecorded)
                                observeAudio(event.recordingStats.audioStats, video, onFailure)
                            }
                            is VideoRecordEvent.Finalize -> {
                                observeAudio(event.recordingStats.audioStats, video, onFailure)
                                phase = Phase.STOPPING
                                recording = null
                                video.put("finalize_callback_epoch_ms", System.currentTimeMillis())
                                video.put("finalize_callback_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                                video.put("encoded_duration_ns", event.recordingStats.recordedDurationNanos)
                                video.put("encoded_bytes", event.recordingStats.numBytesRecorded)
                                video.put("finalize_error_code", event.error)
                                val failure = if (event.hasError()) {
                                    "Phone video finalization error ${event.error}: ${event.cause?.message ?: "CameraX reported an incomplete recording"}"
                                } else null
                                if (failure != null) video.put("failure", failure)
                                releaseCamera()
                                inspectExecutor.execute {
                                    val inspection = inspectTracks(output)
                                    main.post {
                                        if (generation != token) return@post
                                        video.put("tracks", inspection.tracks)
                                        video.put("file_bytes", output.length())
                                        inspection.error?.let { video.put("inspection_error", it) }
                                        metadata.put("phone_video_present", inspection.hasVideo)
                                        metadata.put("phone_audio_present", inspection.hasAudio)
                                        val finalFailure = failure ?: inspection.error
                                            ?: if (!inspection.hasVideo) "Phone output has no video track" else null
                                        video.put("state", if (finalFailure == null) "saved" else "failed")
                                        // Let service error handling call stop() while completion is queued.
                                        if (finalFailure != null) onFailure(finalFailure)
                                        finishStop()
                                    }
                                }
                            }
                        }
                    }
                } catch (error: Exception) {
                    failSetup(video, error, onFailure)
                }
            }, mainExecutor)
        } catch (error: Exception) {
            failSetup(video, error, onFailure)
        }
    }

    override fun stop(onStopped: () -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (phase == Phase.IDLE) {
            onStopped()
            return
        }
        stopCallbacks += onStopped
        if (stopRequested) return
        stopRequested = true
        videoMetadata?.put("stop_requested_elapsed_ns", SystemClock.elapsedRealtimeNanos())
        if (phase == Phase.SETUP) {
            videoMetadata?.put("state", "cancelled_before_camera_ready")
            ++generation
            releaseCamera()
            removeEmptyReservedOutput()
            finishStop()
            return
        }
        if (phase == Phase.STOPPING) return
        phase = Phase.STOPPING
        recording?.stop()
        // CameraX's Finalize event owns completion; the MP4 is not readable before it.
    }

    private fun failSetup(video: JSONObject, error: Exception, onFailure: (String) -> Unit) {
        val message = "Phone video unavailable: ${error.message ?: error.javaClass.simpleName}"
        video.put("state", "failed").put("failure", message)
        releaseCamera()
        removeEmptyReservedOutput()
        phase = Phase.IDLE
        onFailure(message)
        finishStop()
    }

    private fun releaseCamera() {
        activePreview = null
        provider?.let { camera -> runCatching { camera.unbind(*boundUseCases.toTypedArray()) } }
        boundUseCases = emptyList()
        provider = null
    }

    private fun finishStop() {
        phase = Phase.IDLE
        val callbacks = stopCallbacks.toList()
        stopCallbacks.clear()
        callbacks.forEach { it() }
    }

    private fun removeEmptyReservedOutput() {
        // Only this instance's successfully reserved, empty file can be removed.
        reservedOutput?.takeIf { it.exists() && it.length() == 0L }?.delete()
        reservedOutput = null
    }

    private fun hasPermission(permission: String) = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun observeAudio(stats: AudioStats, video: JSONObject, onFailure: (String) -> Unit) {
        video.put("audio_state", stats.audioState)
        if (lastAudioState == stats.audioState) return
        lastAudioState = stats.audioState
        val history = video.optJSONArray("audio_state_changes") ?: JSONArray().also { video.put("audio_state_changes", it) }
        if (history.length() < 32) history.put(JSONObject().put("state", stats.audioState).put("elapsed_ns", SystemClock.elapsedRealtimeNanos()))
        if (stats.hasError() || stats.audioState == AudioStats.AUDIO_STATE_SOURCE_SILENCED) {
            val reason = "Phone audio unavailable or silenced (CameraX state ${stats.audioState}): ${stats.errorCause?.message ?: "system audio source or encoder issue"}; video continues"
            video.put("audio_issue", reason)
            onFailure(reason)
        }
    }

    private data class Inspection(val tracks: JSONArray, val hasVideo: Boolean, val hasAudio: Boolean, val error: String?)

    private fun inspectTracks(file: File): Inspection {
        val tracks = JSONArray()
        var hasVideo = false
        var hasAudio = false
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.absolutePath)
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                hasVideo = hasVideo || mime.startsWith("video/")
                hasAudio = hasAudio || mime.startsWith("audio/")
                val track = JSONObject().put("index", index).put("mime", mime)
                listOf(MediaFormat.KEY_WIDTH, MediaFormat.KEY_HEIGHT, MediaFormat.KEY_FRAME_RATE,
                    MediaFormat.KEY_SAMPLE_RATE, MediaFormat.KEY_CHANNEL_COUNT, MediaFormat.KEY_BIT_RATE,
                    MediaFormat.KEY_ROTATION).forEach { key ->
                    if (format.containsKey(key)) runCatching { track.put(key, format.getInteger(key)) }
                }
                if (format.containsKey(MediaFormat.KEY_DURATION)) track.put("duration_us", format.getLong(MediaFormat.KEY_DURATION))
                if (mime.startsWith("video/")) {
                    // Presentation timestamps stay native in MP4; derive an observed mean rate,
                    // rather than claiming the requested quality implies a fixed frame rate.
                    extractor.selectTrack(index)
                    extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    var count = 0L
                    var firstPts = -1L
                    var lastPts = -1L
                    while (extractor.sampleTime >= 0) {
                        val pts = extractor.sampleTime
                        firstPts = if (firstPts < 0) pts else minOf(firstPts, pts)
                        lastPts = maxOf(lastPts, pts)
                        count++
                        if (!extractor.advance()) break
                    }
                    extractor.unselectTrack(index)
                    track.put("video_sample_count", count)
                    if (firstPts >= 0) track.put("first_presentation_us", firstPts).put("last_presentation_us", lastPts)
                    if (count > 1 && lastPts > firstPts) track.put("observed_mean_fps", (count - 1) * 1_000_000.0 / (lastPts - firstPts))
                    track.put("timing_note", "Container presentation timestamps; not independently measured exposure times")
                }
                tracks.put(track)
            }
            Inspection(tracks, hasVideo, hasAudio, null)
        } catch (error: Exception) {
            Inspection(tracks, hasVideo, hasAudio, "Cannot inspect finalized phone MP4: ${error.message}")
        } finally {
            extractor.release()
        }
    }

    companion object {
        private val inspectExecutor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "phone-video-metadata").apply { isDaemon = true } }
        private var previewSurfaceProvider: Preview.SurfaceProvider? = null
        private var activePreview: Preview? = null

        /** Activity attaches/detaches its view without owning the ongoing recording. */
        fun setPreviewSurfaceProvider(surfaceProvider: Preview.SurfaceProvider?) {
            check(Looper.myLooper() == Looper.getMainLooper())
            previewSurfaceProvider = surfaceProvider
            activePreview?.setSurfaceProvider(surfaceProvider)
        }
    }
}
