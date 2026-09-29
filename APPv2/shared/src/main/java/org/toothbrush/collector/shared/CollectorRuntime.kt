package org.toothbrush.collector.shared

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import org.json.JSONObject
import org.toothbrush.collector.core.Phase
import org.toothbrush.collector.core.RecordingState
import org.toothbrush.collector.core.SessionSpec
import java.io.File

class CollectorApplication : Application() {
    override fun onCreate() { super.onCreate(); CollectorRuntime.init(this) }
}

/** Process-local UI state; recording identity and cancellation tombstones persist separately. */
object CollectorRuntime {
    lateinit var app: Context; private set
    val main = Handler(Looper.getMainLooper())
    val state = RecordingState()
    var visible = false
    var service: RecordingService? = null
    var detail = "Ready"
    var startedElapsedMs = 0L
    var controlOrigin = "Local control"
    var peerId: String? = null
    var peerState = "Unknown"
    var peerSession = ""
    var peerLastSeenMs = 0L
    var peerStatusElapsedMs = 0L
    val peerStatusFresh get() = SystemClock.elapsedRealtime() - peerStatusElapsedMs < 7000
    var peerDetail = ""
    private val statusOrder = org.toothbrush.collector.core.StatusOrder()
    @Volatile var transferStatus = "Files stay on this device"
    val role get() = if (CaptureFactory.isWear) "watch" else "phone"
    val peerRole get() = if (CaptureFactory.isWear) "phone" else "watch"
    val root get() = File(app.filesDir, "recordings").apply { mkdirs() }
    val prefs get() = app.getSharedPreferences("collector", Context.MODE_PRIVATE)
    val connected get() = peerId != null && SystemClock.elapsedRealtime() - peerLastSeenMs < 7000
    private val heartbeat = object : Runnable {
        override fun run() {
            if (visible || state.active) Link.refresh()
            main.postDelayed(this, 2000)
        }
    }
    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        prefs.getStringSet("ended", emptySet())!!.forEach { state.rememberEnded(it) }
        Link.init(app)
        // A process death cannot resume sensors. Recover only local sessions, mark partial, never overwrite data.
        val interruptedDirectories = root.listFiles()?.filter { it.isDirectory && File(it, ".active-$role").exists() }.orEmpty()
        Link.io.execute {
            interruptedDirectories.forEach { dir ->
                val active = File(dir, ".active-$role")
                if (active.exists()) {
                    val recoveryFailures = org.json.JSONArray()
                    dir.listFiles()?.filter { it.extension == "wav" }?.forEach { wav -> runCatching { org.toothbrush.collector.core.WavWriter.recover(wav) }.onFailure { recoveryFailures.put("${wav.name}: ${it.message}") } }
                    val file = dir.listFiles()?.firstOrNull { it.name.startsWith("${role}_metadata_") } ?: return@forEach
                    runCatching {
                        val meta = JSONObject(file.readText()).put("completion", "interrupted_process_death").put("recovered_epoch_ms", System.currentTimeMillis()).put("recovery_failures", recoveryFailures)
                        atomicJson(file, meta); active.delete(); File(dir, ".closed-$role").writeText("interrupted")
                    }
                }
            }
            if (CaptureFactory.isWear) Link.queueFiles()
        }
        main.post(heartbeat)
    }
    fun rememberEnded(id: String) {
        state.rememberEnded(id)
        val set = prefs.getStringSet("ended", emptySet())!!.toMutableSet(); set.add(id)
        // A stale Start also expires after its five-second deadline, so bounded history is sufficient.
        prefs.edit().putStringSet("ended", set.toList().takeLast(256).toSet()).commit()
    }
    fun startLocal(suffix: String) { arm(SessionSpec.create(suffix), true, null) }
    fun arm(spec: SessionSpec, local: Boolean, source: String?) {
        if (!visible) { detail = "Open this app before starting"; source?.let { Link.reject(it, spec, detail) }; return }
        if (service != null && !state.active) { detail = "Finishing previous session · try Start again"; source?.let { Link.reject(it, spec, detail) }; return }
        if (!state.arm(spec, System.currentTimeMillis(), SystemClock.elapsedRealtime())) {
            source?.let { Link.reject(it, spec, "Busy, cancelled, or expired countdown") }; return
        }
        detail = "Starting in 5 seconds"
        startedElapsedMs = 0
        controlOrigin = if (local) "Local control" else "${peerRole.replaceFirstChar { it.uppercase() }} control"
        peerState = "Awaiting confirmation"; peerSession = spec.id
        try {
            val intent = Intent(app, RecordingService::class.java).setAction("ARM").putExtra("session", spec.json().toString()).putExtra("local", local)
            ContextCompat.startForegroundService(app, intent)
        } catch (e: Exception) {
            rememberEnded(spec.id); state.stop(spec.id); state.saved(true); detail = "Start failed: ${e.message}"
            source?.let { Link.reject(it, spec, detail) }
        }
    }
    fun stop(id: String? = state.session?.id, notifyPeer: Boolean = true) {
        id ?: return
        rememberEnded(id)
        if (notifyPeer) Link.sendStop(id)
        if (state.stop(id)) { detail = "Saving…"; service?.finishCapture() }
    }
    fun acceptMessage(node: String, text: String) {
        runCatching {
            val j = JSONObject(text)
            if (j.optInt("version") != 1 || j.optString("role") != peerRole) return
            peerId = node; peerLastSeenMs = SystemClock.elapsedRealtime()
            when (j.getString("type")) {
                "hello" -> { Link.sendStatus(node); Link.resendStops(node); if (!CaptureFactory.isWear) Link.suffix(prefs.getString("suffix", "").orEmpty()) }
                "status" -> {
                    if (!statusOrder.accept(node, j.getString("sender_instance"), j.getLong("sequence"), j.getLong("generation"))) return
                    peerStatusElapsedMs = SystemClock.elapsedRealtime()
                    peerState = j.optString("phase"); peerSession = j.optString("session_id"); peerDetail = j.optString("detail")
                    service?.observePeer(j)
                    val pending = prefs.getStringSet("pending_stops", emptySet())!!.toMutableSet()
                    if (peerSession in pending && peerState in listOf("COUNTDOWN", "STARTING", "RECORDING")) Link.sendStop(peerSession)
                    else if (peerSession in pending) { pending.remove(peerSession); prefs.edit().putStringSet("pending_stops", pending).apply() }
                }
                "start" -> {
                    val spec = sessionFromJson(j.getJSONObject("session"))
                    if (state.session?.id == spec.id && state.active) Link.sendStatus(node) else arm(spec, false, node)
                }
                "stop" -> { val id = j.getString("session_id"); stop(id, false); Link.acknowledgeStop(node, id); Link.sendStatus(node) }
                "stop_ack" -> {
                    val pending = prefs.getStringSet("pending_stops", emptySet())!!.toMutableSet()
                    pending.remove(j.getString("session_id")); prefs.edit().putStringSet("pending_stops", pending).apply()
                }
                "reject" -> {
                    if (j.optString("session_id") == state.session?.id) {
                        peerState = "Unavailable"; peerDetail = j.optString("reason"); service?.observePeer(j)
                    }
                }
                "suffix" -> if (CaptureFactory.isWear) prefs.edit().putString("suffix", org.toothbrush.collector.core.sanitizeSuffix(j.optString("suffix"))).apply()
                "retry" -> if (CaptureFactory.isWear) Link.queueFiles(true)
            }
        }.onFailure { detail = "Ignored invalid peer message" }
    }
    fun peerSummary(): String {
        if (!connected) return "${peerRole.replaceFirstChar { it.uppercase() }} disconnected${if (CaptureFactory.isWear) " · phone video unconfirmed" else ""}"
        if (!peerStatusFresh) return "$peerRole connected · waiting for current status"
        val same = peerSession == state.session?.id
        if (state.active && !same) return "$peerRole connected · no matching recording"
        return "$peerRole: $peerState${if (peerDetail.isNotBlank()) " · $peerDetail" else ""}"
    }
    fun atomicJson(file: File, json: JSONObject) {
        val tmp = File(file.parentFile, ".${file.name}.tmp")
        java.io.FileOutputStream(tmp).use { out -> out.write(json.toString(2).toByteArray()); out.fd.sync() }
        check(tmp.renameTo(file)) { "Cannot save metadata" }
    }
}
