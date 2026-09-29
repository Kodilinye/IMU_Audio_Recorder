package org.toothbrush.collector.wear

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import org.toothbrush.collector.core.SessionSpec
import org.toothbrush.collector.core.WavWriter
import org.toothbrush.collector.shared.Capture
import java.io.BufferedWriter
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/** Acquisition only. The service owns permissions, countdown, wake lock and recording identity. */
class WearCapture(context: Context) : Capture {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var active: Recording? = null

    override fun start(
        directory: File,
        session: SessionSpec,
        metadata: JSONObject,
        onStarted: () -> Unit,
        onFailure: (String) -> Unit,
    ) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Capture lifecycle must run on main" }
        if (active != null) {
            onFailure("Watch acquisition already active")
            return
        }
        active = Recording(directory, session, metadata, onStarted, onFailure).also { it.begin() }
    }

    override fun stop(onStopped: () -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Capture lifecycle must run on main" }
        val recording = active
        if (recording == null) onStopped() else recording.stop(onStopped)
    }

    private inner class Recording(
        val directory: File,
        val session: SessionSpec,
        val metadata: JSONObject,
        val onStarted: () -> Unit,
        val onFailure: (String) -> Unit,
    ) : SensorEventListener {
        private val stopping = AtomicBoolean(false)
        private val started = AtomicBoolean(false)
        private val audioEnded = AtomicBoolean(false)
        private var exhaustionReported = false
        private val failures = ConcurrentLinkedQueue<JSONObject>()
        private val thread = HandlerThread("collector-sensors", Process.THREAD_PRIORITY_MORE_FAVORABLE)
            .apply { start() }
        private val handler = Handler(thread.looper)
        private val manager = app.getSystemService(SensorManager::class.java)
        private var writer: BufferedWriter? = null
        private var overflowWriter: BufferedWriter? = null
        private var audioThread: Thread? = null
        private val sensorInfo = JSONArray()
        private val stats = linkedMapOf<Int, SensorStats>()
        private val motion = JSONObject()
        // Written only by the audio thread, read after joining it.
        private val audio = JSONObject()
        private val stopCallbacks = mutableListOf<() -> Unit>()
        private val startElapsedNs = SystemClock.elapsedRealtimeNanos()
        private var lastFlushNs = startElapsedNs

        fun begin() {
            handler.post {
                if (stopping.get()) return@post
                try {
                    check(directory.isDirectory || directory.mkdirs()) { "Cannot create recording directory" }
                    startMotion()
                } catch (error: Exception) {
                    fail("motion", "Cannot start motion: ${error.message}")
                }
                if (!stopping.get()) {
                    audioThread = Thread({ recordAudio() }, "collector-audio").apply { start() }
                    handler.postDelayed(healthCheck, 1_000)
                }
            }
        }

        private fun startMotion() {
            val file = File(directory, "motion_native_${session.stem}.csv")
            check(file.createNewFile()) { "Refusing to overwrite ${file.name}" }
            writer = file.bufferedWriter().apply {
                write("sensor_type,event_timestamp_ns,arrival_elapsed_ns,accuracy,v0,v1,v2,v3,v4,v5\n")
                flush()
            }
            motion.put("file", file.name)
                .put("schema", "android_sensor_events_v1")
                .put("requested_period_us", 10_000)
                .put("requested_max_report_latency_us", 0)
                .put("timestamp_timebase", "elapsedRealtimeNanos; includes time in deep sleep")
                .put("axes", "Android default display orientation: x right, y up, z out of screen; no remapping")
                .put("rotation_reference", "TYPE_ROTATION_VECTOR magnetic ENU; TYPE_GAME_ROTATION_VECTOR arbitrary yaw")
                .put("processing", "Unmodified sensor event values; no synchronization, interpolation or unit conversion")
                .put("sensors", sensorInfo)
            for (type in SENSOR_TYPES) {
                if (stopping.get()) break
                val sensor = manager.getDefaultSensor(type)
                val info = JSONObject().put("type", type).put("available", sensor != null)
                    .put("name", sensorName(type)).put("units", units(type))
                sensorInfo.put(info)
                if (sensor == null) continue
                info.put("android_name", sensor.name).put("vendor", sensor.vendor)
                    .put("version", sensor.version).put("string_type", sensor.stringType)
                    .put("minimum_delay_us", sensor.minDelay).put("maximum_delay_us", sensor.maxDelay)
                    .put("resolution", sensor.resolution.toDouble()).put("maximum_range", sensor.maximumRange.toDouble())
                    .put("power_ma", sensor.power.toDouble()).put("wake_up", sensor.isWakeUpSensor)
                    .put("reporting_mode", sensor.reportingMode).put("fifo_max_events", sensor.fifoMaxEventCount)
                val registered = try {
                    manager.registerListener(this, sensor, 10_000, 0, handler)
                } catch (error: Exception) {
                    fail("motion", "${sensorName(type)} registration failed: ${error.message}")
                    false
                }
                info.put("registered", registered)
                if (registered) stats[type] = SensorStats(info) else {
                    fail("motion", "${sensorName(type)} is available but could not be registered")
                }
            }
            val initialMotion = JSONObject(motion.toString())
            main.post { if (active === this) metadata.put("motion", initialMotion) }
            if (stats.isEmpty()) fail("motion", "No motion sensors could be registered; audio may still record")
        }

        override fun onSensorChanged(event: SensorEvent) {
            if (stopping.get()) return
            val output = writer ?: return
            val arrival = SystemClock.elapsedRealtimeNanos()
            try {
                val row = StringBuilder(192).append(event.sensor.type).append(',')
                    .append(event.timestamp).append(',').append(arrival).append(',').append(event.accuracy)
                for (index in 0..5) {
                    row.append(',')
                    if (index < event.values.size) row.append(event.values[index])
                }
                row.append('\n')
                output.write(row.toString())
                // Standard requested Android vectors fit six columns. Preserve vendor extensions too.
                if (event.values.size > 6) {
                    if (overflowWriter == null) {
                        val file = File(directory, "motion_extra_${session.stem}.jsonl")
                        check(file.createNewFile()) { "Refusing to overwrite ${file.name}" }
                        overflowWriter = file.bufferedWriter()
                        motion.put("extended_value_file", file.name)
                    }
                    val values = JSONArray()
                    event.values.forEach { values.put(it.toString()) }
                    overflowWriter!!.write(JSONObject().put("sensor_type", event.sensor.type)
                        .put("event_timestamp_ns", event.timestamp).put("values", values).toString() + "\n")
                }
                stats[event.sensor.type]?.observe(event.timestamp, arrival, event.values.size, event.accuracy)
                if (!started.get()) output.flush()
                signalStarted()
            } catch (error: Exception) {
                fail("motion", "Motion write failed: ${error.message}; saved data may be partial")
                manager.unregisterListener(this)
                closeMotion()
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
            // Every sample already carries accuracy. No synthetic samples are inserted here.
        }

        private val healthCheck = object : Runnable {
            override fun run() {
                if (stopping.get()) return
                val now = SystemClock.elapsedRealtimeNanos()
                stats.forEach { (type, stat) ->
                    if (now - max(stat.lastArrivalNs, startElapsedNs) > 3_000_000_000L && !stat.stallReported) {
                        stat.stallReported = true
                        stat.stalls++
                        fail("motion", "${sensorName(type)} has delivered no sample for 3 seconds")
                    }
                }
                try {
                    writer?.flush()
                    overflowWriter?.flush()
                    lastFlushNs = now
                } catch (error: Exception) {
                    fail("motion", "Motion flush failed: ${error.message}")
                    manager.unregisterListener(this@Recording)
                    closeMotion()
                }
                handler.postDelayed(this, 1_000)
            }
        }

        private fun signalStarted() {
            if (stopping.get() || !started.compareAndSet(false, true)) return
            val firstSaved = SystemClock.elapsedRealtimeNanos()
            main.post {
                if (active === this && !stopping.get()) {
                    metadata.put("first_watch_data_saved_elapsed_ns", firstSaved)
                    onStarted()
                }
            }
        }

        private fun fail(stream: String, message: String, exhausted: Boolean = false) {
            failures.add(JSONObject().put("stream", stream).put("message", message)
                .put("elapsed_ns", SystemClock.elapsedRealtimeNanos()))
            main.post {
                if (active === this) {
                    if (exhausted) metadata.put("capture_streams_exhausted", true)
                    onFailure(message)
                }
            }
        }

        private fun checkExhausted() {
            if (!stopping.get() && audioEnded.get() && (writer == null || stats.isEmpty()) && !exhaustionReported) {
                exhaustionReported = true
                fail("capture", "No active watch capture streams remain; saving partial files", exhausted = true)
            }
        }

        private fun recordAudio() {
            var recorder: AudioRecord? = null
            var wav: WavWriter? = null
            var frames = 0L
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
                val audioManager = app.getSystemService(AudioManager::class.java)
                val supportsUnprocessed = audioManager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
                audio.put("unprocessed_advertised", supportsUnprocessed)
                    .put("app_processing", "none; PCM samples written without filtering or resampling")
                    .put("preferred_sample_rate_hz", 44_100)
                    .put("overrun_detection", "AudioRecord exposes no portable overrun counter; timestamp and read-gap observations only")
                val attempts = JSONArray()
                audio.put("configuration_attempts", attempts)
                val sources = if (supportsUnprocessed) listOf(MediaRecorder.AudioSource.UNPROCESSED, MediaRecorder.AudioSource.VOICE_RECOGNITION)
                    else listOf(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                val preferredMic = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
                for (source in sources) {
                    for (rate in listOf(44_100, 48_000, 16_000)) {
                        if (stopping.get()) return
                        var candidate: AudioRecord? = null
                        try {
                            candidate = openAudio(source, rate, preferredMic)
                            var deviceRate = candidate.activeRecordingConfiguration?.format?.sampleRate ?: 0
                            // Avoid known framework resampling when the physical capture rate is exposed.
                            if (deviceRate > 0 && deviceRate != candidate.sampleRate) {
                                attempts.put(JSONObject().put("source", source).put("requested_hz", rate)
                                    .put("device_hz", deviceRate).put("result", "reopening_at_device_rate"))
                                candidate.stop()
                                candidate.release()
                                candidate = null
                                candidate = openAudio(source, deviceRate, preferredMic)
                                deviceRate = candidate.activeRecordingConfiguration?.format?.sampleRate ?: 0
                                check(deviceRate == 0 || deviceRate == candidate.sampleRate) {
                                    "Device rate differs from client rate after reopening; refusing known resampling"
                                }
                            }
                            attempts.put(JSONObject().put("source", source).put("requested_hz", rate)
                                .put("selected_hz", candidate.sampleRate).put("result", "started"))
                            recorder = candidate
                            break
                        } catch (error: Exception) {
                            runCatching { candidate?.stop() }
                            candidate?.release()
                            attempts.put(JSONObject().put("source", source).put("requested_hz", rate)
                                .put("result", "failed").put("error", error.message ?: error.javaClass.simpleName))
                        }
                    }
                    if (recorder != null) break
                }
                val input = recorder ?: throw IllegalStateException("No supported PCM16 microphone configuration")
                if (stopping.get()) return
                val file = File(directory, "audio_${session.stem}.wav")
                check(!file.exists()) { "Refusing to overwrite ${file.name}" }
                wav = WavWriter(file, input.sampleRate, input.channelCount)
                audio.put("file", file.name).put("sample_rate_hz", input.sampleRate)
                    .put("channels", input.channelCount).put("encoding", "PCM16_LE")
                    .put("source", input.audioSource).put("buffer_frames", input.bufferSizeInFrames)
                    .put("platform_processing", if (input.audioSource == MediaRecorder.AudioSource.UNPROCESSED)
                        "UNPROCESSED advertised and selected; hardware path still requires validation"
                    else "VOICE_RECOGNITION fallback; vendor processing is not guaranteed absent")
                    .put("file_opened_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                    .put("device_rate_verification", if (input.activeRecordingConfiguration?.format?.sampleRate?.let { it > 0 } == true)
                        "Device and client rate checked before PCM file creation"
                    else "Device configuration not exposed; native-rate equivalence remains unverified")
                val initialAudio = JSONObject(audio.toString())
                main.post { if (active === this) metadata.put("audio", initialAudio) }
                val samples = ShortArray(2048)
                val bytes = ByteArray(samples.size * 2)
                var lastReadNs = SystemClock.elapsedRealtimeNanos()
                var lastObserveNs = 0L
                var lastConfig = ""
                var lastSilenced = false
                var maxReadGapNs = 0L
                var gapWarnings = 0L
                var stallReported = false
                var previousFramePosition: Long? = null
                var previousTimestampNs: Long? = null
                var timestampRegressions = 0L
                val observations = JSONArray()
                audio.put("configuration_changes", observations)
                while (!stopping.get()) {
                    val count = input.read(samples, 0, samples.size, AudioRecord.READ_NON_BLOCKING)
                    val now = SystemClock.elapsedRealtimeNanos()
                    if (count < 0) throw IllegalStateException("AudioRecord.read returned $count")
                    if (count > 0) {
                        // Byte order conversion only; numerical PCM sample values are unchanged.
                        for (i in 0 until count) {
                            bytes[i * 2] = (samples[i].toInt() and 0xff).toByte()
                            bytes[i * 2 + 1] = (samples[i].toInt() ushr 8).toByte()
                        }
                        wav.write(bytes, count * 2)
                        if (frames == 0L) audio.put("first_read_elapsed_ns", now)
                        frames += count / input.channelCount
                        maxReadGapNs = max(maxReadGapNs, now - lastReadNs)
                        val bufferDurationNs = input.bufferSizeInFrames.toLong() * 1_000_000_000L / input.sampleRate
                        if (now - lastReadNs > bufferDurationNs && frames > count) {
                            gapWarnings++
                            if (gapWarnings == 1L) fail("audio", "Audio read gap exceeded the device buffer duration; possible sample loss")
                        }
                        lastReadNs = now
                        stallReported = false
                        signalStarted()
                    } else {
                        if (now - lastReadNs > 3_000_000_000L && !stallReported) {
                            stallReported = true
                            fail("audio", "Microphone has delivered no PCM data for 3 seconds")
                        }
                        Thread.sleep(10)
                    }
                    if (now - lastObserveNs >= 1_000_000_000L) {
                        lastObserveNs = now
                        val timestamp = AudioTimestamp()
                        val timestampResult = input.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_BOOTTIME)
                        audio.put("last_timestamp_result", timestampResult)
                        if (timestampResult == AudioRecord.SUCCESS) {
                            val point = JSONObject().put("frame_position", timestamp.framePosition)
                                .put("timestamp_ns", timestamp.nanoTime).put("observed_elapsed_ns", now)
                                .put("frames_written", frames).put("timebase", "BOOTTIME")
                            if (!audio.has("first_audio_timestamp")) audio.put("first_audio_timestamp", point)
                            audio.put("last_audio_timestamp", point)
                            if ((previousFramePosition != null && timestamp.framePosition < previousFramePosition!!) ||
                                (previousTimestampNs != null && timestamp.nanoTime < previousTimestampNs!!)) {
                                timestampRegressions++
                                fail("audio", "Microphone timestamp regressed; inspect audio timing metadata")
                            }
                            previousFramePosition = timestamp.framePosition
                            previousTimestampNs = timestamp.nanoTime
                        }
                        val config = input.activeRecordingConfiguration
                        val route = input.routedDevice
                        val snapshot = JSONObject().put("client_format", audioFormat(input.format))
                            .put("device_format", config?.format?.let { audioFormat(it) } ?: JSONObject.NULL)
                            .put("device_audio_source", config?.audioSource ?: JSONObject.NULL)
                            .put("capture_effects", config?.effects?.let { effects -> JSONArray(effects.map { it.name }) } ?: JSONObject.NULL)
                            .put("client_silenced", config?.isClientSilenced ?: JSONObject.NULL)
                            .put("routed_device", route?.let { audioDevice(it) } ?: JSONObject.NULL)
                        if (snapshot.toString() != lastConfig) {
                            lastConfig = snapshot.toString()
                            observations.put(snapshot.put("observed_elapsed_ns", now))
                        }
                        if (config?.isClientSilenced == true && !lastSilenced) {
                            fail("audio", "Android silenced microphone capture; PCM during this interval may contain silence")
                        }
                        lastSilenced = config?.isClientSilenced == true
                        if (config != null && config.format.sampleRate > 0 && config.format.sampleRate != input.sampleRate) {
                            throw IllegalStateException("Microphone route now requires resampling; audio stopped to preserve native rate")
                        }
                        audio.put("maximum_read_gap_ns", maxReadGapNs).put("possible_overrun_read_gaps", gapWarnings)
                            .put("timestamp_regressions", timestampRegressions).put("frames_written", frames)
                        val checkpoint = JSONObject(audio.toString())
                        main.post { if (active === this && !stopping.get()) metadata.put("audio", checkpoint) }
                    }
                }
            } catch (error: InterruptedException) {
                if (!stopping.get()) fail("audio", "Audio worker interrupted unexpectedly")
            } catch (error: Exception) {
                audio.put("failure", error.message ?: error.javaClass.simpleName)
                fail("audio", "Audio stopped: ${error.message}; motion may still record")
            } finally {
                runCatching { recorder?.stop() }.onFailure {
                    fail("audio", "Microphone stop failed: ${it.message}")
                }
                runCatching { recorder?.release() }.onFailure { fail("audio", "Microphone release failed: ${it.message}") }
                runCatching { wav?.close() }.onFailure { fail("audio", "WAV finalization failed: ${it.message}") }
                audio.put("frames_written", frames).put("ended_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                    .put("has_samples", frames > 0)
                audioEnded.set(true)
                handler.post { checkExhausted() }
            }
        }

        private fun openAudio(source: Int, rate: Int, preferredMic: AudioDeviceInfo?): AudioRecord {
            if (app.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                throw SecurityException("Microphone permission is not granted")
            }
            val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "Unsupported sample rate $rate" }
            val record = AudioRecord.Builder().setAudioSource(source)
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
                // Leave room for native configuration discovery before the first read.
                .setBufferSizeInBytes(max(minimum * 4, rate)).build()
            try {
                check(record.state == AudioRecord.STATE_INITIALIZED) { "Microphone did not initialize" }
                if (preferredMic != null) audio.put("builtin_microphone_preference_accepted", record.setPreferredDevice(preferredMic))
                audio.put("recording_start_call_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                record.startRecording()
                audio.put("recording_started_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Microphone did not start" }
                // Configuration can appear a few milliseconds after starting the route.
                var attempts = 0
                while (!stopping.get() && record.activeRecordingConfiguration == null && attempts++ < 20) {
                    Thread.sleep(10)
                }
                return record
            } catch (error: Exception) {
                record.release()
                throw error
            }
        }

        fun stop(onStopped: () -> Unit) {
            stopCallbacks.add(onStopped)
            if (!stopping.compareAndSet(false, true)) return
            handler.post {
                handler.removeCallbacks(healthCheck)
                manager.unregisterListener(this)
                closeMotion()
                // Nonblocking AudioRecord reads ensure Stop does not depend on more microphone data.
                audioThread?.interrupt()
                audioThread?.join()
                stats.values.forEach { it.finish() }
                motion.put("last_flush_elapsed_ns", lastFlushNs)
                    .put("has_samples", stats.values.any { it.count > 0 })
                val failureArray = JSONArray()
                failures.forEach { failureArray.put(it) }
                main.post {
                    metadata.put("motion", motion).put("audio", audio).put("capture_failures", failureArray)
                        .put("watch_capture_start_elapsed_ns", startElapsedNs)
                        .put("watch_capture_stop_elapsed_ns", SystemClock.elapsedRealtimeNanos())
                    if (active === this) active = null
                    stopCallbacks.toList().forEach { it() }
                    stopCallbacks.clear()
                }
                thread.quitSafely()
            }
        }

        private fun closeMotion() {
            runCatching { writer?.close() }.onFailure { fail("motion", "Motion close failed: ${it.message}") }
            writer = null
            runCatching { overflowWriter?.close() }.onFailure { fail("motion", "Extended motion close failed: ${it.message}") }
            overflowWriter = null
            checkExhausted()
        }
    }

    private class SensorStats(val info: JSONObject) {
        var count = 0L
        var firstTimestampNs = 0L
        var lastTimestampNs = 0L
        var firstArrivalNs = 0L
        var lastArrivalNs = 0L
        var maximumGapNs = 0L
        var nonmonotonicCount = 0L
        var longGapCount = 0L
        var stalls = 0L
        var stallReported = false
        var minLength = Int.MAX_VALUE
        var maxLength = 0
        val accuracyCounts = mutableMapOf<Int, Long>()

        fun observe(timestamp: Long, arrival: Long, length: Int, accuracy: Int) {
            if (count == 0L) {
                firstTimestampNs = timestamp
                firstArrivalNs = arrival
            } else {
                val gap = timestamp - lastTimestampNs
                maximumGapNs = max(maximumGapNs, gap)
                if (gap <= 0) nonmonotonicCount++
                if (gap > 50_000_000L) longGapCount++
            }
            count++
            lastTimestampNs = timestamp
            lastArrivalNs = arrival
            stallReported = false
            minLength = minOf(minLength, length)
            maxLength = max(maxLength, length)
            accuracyCounts[accuracy] = (accuracyCounts[accuracy] ?: 0) + 1
        }

        fun finish() {
            info.put("sample_count", count).put("stalls_over_3s", stalls)
            if (count == 0L) return
            info.put("first_event_timestamp_ns", firstTimestampNs).put("last_event_timestamp_ns", lastTimestampNs)
                .put("first_arrival_elapsed_ns", firstArrivalNs).put("last_arrival_elapsed_ns", lastArrivalNs)
                .put("maximum_interval_ns", maximumGapNs).put("intervals_over_50ms", longGapCount)
                .put("nonmonotonic_timestamps", nonmonotonicCount)
                .put("minimum_values_length", minLength).put("maximum_values_length", maxLength)
                .put("accuracy_counts", JSONObject(accuracyCounts.mapKeys { it.key.toString() }))
            if (count > 1 && lastTimestampNs > firstTimestampNs) {
                info.put("observed_rate_hz", (count - 1) * 1e9 / (lastTimestampNs - firstTimestampNs))
            }
        }
    }

    private fun audioFormat(format: AudioFormat) = JSONObject().put("sample_rate_hz", format.sampleRate)
        .put("channel_count", format.channelCount).put("encoding", format.encoding)

    private fun audioDevice(device: AudioDeviceInfo) = JSONObject().put("id", device.id)
        .put("type", device.type).put("name", device.productName.toString())
        .put("advertised_sample_rates", JSONArray(device.sampleRates.toList()))

    private fun sensorName(type: Int): String = when (type) {
        Sensor.TYPE_ACCELEROMETER -> "accelerometer_including_gravity"
        Sensor.TYPE_LINEAR_ACCELERATION -> "linear_acceleration"
        Sensor.TYPE_GYROSCOPE -> "gyroscope"
        Sensor.TYPE_MAGNETIC_FIELD -> "magnetic_field"
        Sensor.TYPE_GRAVITY -> "gravity"
        Sensor.TYPE_ROTATION_VECTOR -> "rotation_vector"
        Sensor.TYPE_GAME_ROTATION_VECTOR -> "game_rotation_vector"
        else -> "sensor_$type"
    }

    private fun units(type: Int): String = when (type) {
        Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_LINEAR_ACCELERATION, Sensor.TYPE_GRAVITY -> "m/s^2"
        Sensor.TYPE_GYROSCOPE -> "rad/s"
        Sensor.TYPE_MAGNETIC_FIELD -> "uT"
        Sensor.TYPE_ROTATION_VECTOR -> "v0..v3 quaternion x,y,z,w; v4 heading accuracy rad when present"
        Sensor.TYPE_GAME_ROTATION_VECTOR -> "v0..v3 quaternion x,y,z,w; remaining vendor values preserved"
        else -> "native"
    }

    companion object {
        private val SENSOR_TYPES = listOf(Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_LINEAR_ACCELERATION,
            Sensor.TYPE_GYROSCOPE, Sensor.TYPE_MAGNETIC_FIELD, Sensor.TYPE_GRAVITY,
            Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_GAME_ROTATION_VECTOR)
    }
}
