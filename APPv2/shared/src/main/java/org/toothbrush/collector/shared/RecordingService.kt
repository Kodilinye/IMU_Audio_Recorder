package org.toothbrush.collector.shared

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import androidx.lifecycle.LifecycleService
import org.json.JSONArray
import org.json.JSONObject
import org.toothbrush.collector.core.Phase
import org.toothbrush.collector.core.SessionSpec
import java.io.File

/** Foreground ownership of sensors/camera survives Activity recreation and wrist-down. */
class RecordingService : LifecycleService() {
    private val runtime = CollectorRuntime
    private var spec: SessionSpec? = null
    private var capture: Capture? = null
    private var directory: File? = null
    private var metadata = JSONObject()
    private val failures = JSONArray()
    private var wake: PowerManager.WakeLock? = null
    private var finishing = false
    private var startTask: Runnable? = null
    private var startTimeout: Runnable? = null
    private var foreground = false
    private var cleanupFailed = false
    private val checkpoint = object : Runnable {
        override fun run() {
            if (finishing) return
            wake?.acquire(10 * 60 * 1000L)
            runCatching { saveMetadata() }.onFailure { failure("Metadata checkpoint: ${it.message}") }
            runtime.main.postDelayed(this, 5000)
        }
    }

    override fun onCreate() { super.onCreate(); runtime.service = this }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == "STOP") { runtime.stop(intent.getStringExtra("session_id")); if (spec == null) stopSelf(); return START_NOT_STICKY }
        if (intent?.action != "ARM" || spec != null) return START_NOT_STICKY
        try {
            val s = sessionFromJson(JSONObject(intent.getStringExtra("session")!!)); spec = s
            showForeground("Countdown · tap Stop to cancel")
            if (runtime.state.session?.id != s.id || runtime.state.phase != Phase.COUNTDOWN) { finishCapture(); return START_NOT_STICKY }
            val dir = File(runtime.root, s.id)
            check(!dir.exists()) { "Session directory already exists" }; check(dir.mkdirs()) { "Cannot create recording directory" }; directory = dir
            val before = SystemClock.elapsedRealtimeNanos(); val epoch = System.currentTimeMillis(); val after = SystemClock.elapsedRealtimeNanos()
            metadata = JSONObject().put("schema_version", 1).put("role", runtime.role).put("session", s.json())
                .put("clock_anchor", JSONObject().put("epoch_ms", epoch).put("elapsed_ns", before + (after - before) / 2).put("read_span_ns", after - before))
                .put("device", JSONObject().put("manufacturer", Build.MANUFACTURER).put("model", Build.MODEL).put("product", Build.PRODUCT)
                    .put("sdk", Build.VERSION.SDK_INT).put("release", Build.VERSION.RELEASE).put("fingerprint", Build.FINGERPRINT))
                .put("control_origin", runtime.controlOrigin).put("app_version", "1.0").put("completion", "countdown").put("failures", failures)
                .put("synchronization", "Shared wall-clock target only; clocks and stream start latencies are not precisely synchronized")
                .put("phone_video", if (CaptureFactory.isWear) "unconfirmed" else "pending")
            saveMetadata(); runtime.main.postDelayed(checkpoint, 5000); File(dir, ".active-${runtime.role}").writeText(s.id)
            wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:capture").apply { setReferenceCounted(false); acquire(10 * 60 * 1000L) }
            if (intent.getBooleanExtra("local", false)) Link.sendStart(s)
            Link.sendStatus()
            startTask = Runnable {
                if (!runtime.state.due(s.id, SystemClock.elapsedRealtime())) return@Runnable
                runtime.detail = "Opening recorder…"
                metadata.put("capture_requested_elapsed_ns", SystemClock.elapsedRealtimeNanos()).put("completion", "starting")
                capture = CaptureFactory.create(this)
                startTimeout = Runnable {
                    if (runtime.state.phase == Phase.STARTING && runtime.state.session?.id == s.id) { failure("No capture data within 10 seconds"); runtime.stop(s.id) }
                }.also { runtime.main.postDelayed(it, 10000) }
                try {
                    capture!!.start(dir, s, metadata, {
                        runtime.main.post {
                            if (runtime.state.started(s.id)) {
                                runtime.startedElapsedMs = SystemClock.elapsedRealtime()
                                metadata.put("first_capture_callback_elapsed_ns", SystemClock.elapsedRealtimeNanos()).put("completion", "recording")
                                runtime.detail = if (failures.length() > 0) "Recording · ${failures.optString(failures.length() - 1)}" else if (!CaptureFactory.isWear && !metadata.optBoolean("phone_audio_present", false)) "Recording video only · phone microphone unavailable" else "Recording"
                                showForeground("Recording · Stop saves locally"); saveMetadata(); Link.sendStatus()
                            }
                        }
                    }, { reason -> runtime.main.post { failure(reason) } })
                } catch (e: Exception) { failure("Capture start: ${e.message}"); runtime.stop(s.id) }
            }.also { runtime.main.postDelayed(it, (runtime.state.deadlineElapsedMs - SystemClock.elapsedRealtime()).coerceAtLeast(0)) }
        } catch (e: Exception) {
            failure("Start failed: ${e.message}")
            spec?.let { runtime.rememberEnded(it.id); runtime.state.stop(it.id) }
            finishCapture()
        }
        return START_NOT_STICKY
    }
    private fun failure(reason: String) {
        if (failures.length() < 100) failures.put(reason)
        runtime.detail = "${if (runtime.state.phase == Phase.RECORDING) "Recording with issue" else "Capture issue"}: $reason"
        runCatching { saveMetadata() }; Link.sendStatus()
        if (!finishing && (metadata.optBoolean("capture_streams_exhausted") ||
            (!CaptureFactory.isWear && metadata.optJSONObject("phone_video")?.optString("state") == "failed"))) {
            runtime.stop(spec?.id, notifyPeer = false)
        }
    }
    fun observePeer(message: JSONObject) {
        if (spec == null || finishing) return
        metadata.put("peer_last_observation", JSONObject(message.toString()).put("received_elapsed_ns", SystemClock.elapsedRealtimeNanos()))
        if (CaptureFactory.isWear) metadata.put("phone_video", when {
            message.optString("type") == "reject" -> "absent: ${message.optString("reason") }"
            message.optString("session_id") != spec!!.id -> "no_matching_phone_session"
            message.optString("phase") == "RECORDING" -> "phone_reports_recording"
            else -> "phone_reports_${message.optString("phase")}"
        })
        runCatching { saveMetadata() }
    }
    fun finishCapture() {
        if (finishing) return
        finishing = true
        runtime.main.removeCallbacks(checkpoint)
        startTask?.let { runtime.main.removeCallbacks(it) }; startTimeout?.let { runtime.main.removeCallbacks(it) }
        val done = {
            runtime.main.post {
                metadata.put("stopped_elapsed_ns", SystemClock.elapsedRealtimeNanos()).put("stopped_epoch_ms", System.currentTimeMillis())
                    .put("completion", if (cleanupFailed) "cleanup_failed_unverified" else if (runtime.startedElapsedMs == 0L) { if (metadata.has("capture_requested_elapsed_ns")) "stopped_before_start_confirmation" else "cancelled_during_countdown" } else if (failures.length() > 0) "completed_with_issues" else "completed")
                    .put("peer_reachable_at_stop", runtime.connected).put("failures", failures)
                runCatching {
                    saveMetadata()
                    if (!cleanupFailed) directory?.let { dir -> File(dir, ".active-${runtime.role}").delete(); File(dir, ".closed-${runtime.role}").writeText("closed") }
                }.onFailure { failures.put("Save metadata: ${it.message}") }
                wake?.let { if (it.isHeld) it.release() }; wake = null
                spec?.let { runtime.rememberEnded(it.id) }
                runtime.state.saved(failures.length() > 0)
                runtime.detail = if (failures.length() > 0) "Saved with issue: ${failures.optString(failures.length() - 1)}" else if (runtime.startedElapsedMs == 0L) { if (metadata.has("capture_requested_elapsed_ns")) "Stopped during setup · inspect partial files" else "Cancelled · no recording" } else "Saved locally"
                Link.sendStatus()
                if (CaptureFactory.isWear) Link.queueFiles()
                if (foreground) stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            Unit
        }
        val recorder = capture
        if (recorder == null) done() else try { recorder.stop(done) } catch (e: Exception) { cleanupFailed = true; failures.put("Stop cleanup unverified: ${e.message}"); done() }
    }
    private fun saveMetadata() {
        val s = spec ?: return; val dir = directory ?: return
        CollectorRuntime.atomicJson(File(dir, "${runtime.role}_metadata_${s.stem}.json"), metadata)
    }
    private fun showForeground(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("recording", "Recording", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, CollectorActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, RecordingService::class.java).setAction("STOP").setData(android.net.Uri.parse("collector://stop/${spec?.id}")).putExtra("session_id", spec?.id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "recording").setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Toothbrush Collector").setContentText(text).setOngoing(true).setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop & save", stop).build()).build()
        val hasMic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val type = if (CaptureFactory.isWear) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or if (hasMic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
        if (Build.VERSION.SDK_INT >= 30) startForeground(10, notification, type) else startForeground(10, notification)
        foreground = true
    }
    override fun onDestroy() {
        if (!finishing && spec != null) {
            failure("Service destroyed during capture"); runtime.stop(notifyPeer = false)
        }
        if (runtime.service === this) runtime.service = null
        super.onDestroy()
    }
}
