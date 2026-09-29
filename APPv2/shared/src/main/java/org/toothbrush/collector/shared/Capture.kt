package org.toothbrush.collector.shared

import org.json.JSONObject
import org.toothbrush.collector.core.SessionSpec
import java.io.File

interface Capture {
    fun start(directory: File, session: SessionSpec, metadata: JSONObject, onStarted: () -> Unit, onFailure: (String) -> Unit)
    /** Must drain writers and finalize containers before invoking onStopped on the main thread. */
    fun stop(onStopped: () -> Unit)
}
fun SessionSpec.json() = JSONObject().put("id", id).put("stem", stem).put("scheduled_epoch_ms", scheduledEpochMs)
    .put("created_epoch_ms", createdEpochMs).put("suffix", suffix)
fun sessionFromJson(j: JSONObject) = SessionSpec(j.getString("id"), j.getString("stem"), j.getLong("scheduled_epoch_ms"), j.getLong("created_epoch_ms"), j.optString("suffix"))
