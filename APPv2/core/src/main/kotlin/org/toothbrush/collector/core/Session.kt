package org.toothbrush.collector.core

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/** Immutable identity carried by every command; files live in UUID directories. */
data class SessionSpec(val id: String, val stem: String, val scheduledEpochMs: Long, val createdEpochMs: Long, val suffix: String) {
    fun valid(): Boolean = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false) &&
        stem.matches(Regex("[0-9]{8}_[0-9]{6}(?:_[\\p{L}\\p{N}_-]{1,64})?")) &&
        suffix == sanitizeSuffix(suffix) && scheduledEpochMs - createdEpochMs == 5000L
    companion object {
        fun create(suffix: String, now: Long = System.currentTimeMillis()): SessionSpec {
            val clean = sanitizeSuffix(suffix)
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(now))
            return SessionSpec(UUID.randomUUID().toString(), stamp + if (clean.isEmpty()) "" else "_$clean", now + 5000, now, clean)
        }
    }
}
fun sanitizeSuffix(raw: String): String = raw.trim().filter { it.isLetterOrDigit() || it == '_' || it == '-' }.take(64)

enum class Phase { IDLE, COUNTDOWN, STARTING, RECORDING, SAVING, ERROR }

/** Main-thread state machine. A cancelled identity can never be armed again. */
class RecordingState {
    var phase: Phase = Phase.IDLE; private set
    var session: SessionSpec? = null; private set
    var deadlineElapsedMs: Long = 0; private set
    private val ended = LinkedHashSet<String>()
    val active get() = phase in setOf(Phase.COUNTDOWN, Phase.STARTING, Phase.RECORDING, Phase.SAVING)
    fun rememberEnded(id: String) { ended.add(id); while (ended.size > 256) ended.remove(ended.first()) }
    fun arm(spec: SessionSpec, wallMs: Long, elapsedMs: Long): Boolean {
        if (active || !spec.valid() || spec.id in ended || spec.scheduledEpochMs <= wallMs || spec.scheduledEpochMs - wallMs > 6000) return false
        session = spec; deadlineElapsedMs = elapsedMs + spec.scheduledEpochMs - wallMs; phase = Phase.COUNTDOWN
        return true
    }
    fun due(id: String, elapsedMs: Long): Boolean {
        if (phase != Phase.COUNTDOWN || session?.id != id || elapsedMs < deadlineElapsedMs) return false
        phase = Phase.STARTING; return true
    }
    fun started(id: String): Boolean {
        if (phase != Phase.STARTING || session?.id != id) return false
        phase = Phase.RECORDING; return true
    }
    fun stop(id: String): Boolean {
        rememberEnded(id)
        if (session?.id != id || !active || phase == Phase.SAVING) return false
        phase = Phase.SAVING; return true
    }
    fun saved(failed: Boolean = false) { phase = if (failed) Phase.ERROR else Phase.IDLE }
}
