package org.toothbrush.collector.shared

import android.content.Context
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.*
import org.json.JSONObject
import org.toothbrush.collector.core.Integrity
import org.toothbrush.collector.core.SessionSpec
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/** Data Layer assets are durable across disconnection. Commands use messages and expire. */
object Link {
    val io = Executors.newSingleThreadExecutor()
    private lateinit var context: Context
    private val runtime get() = CollectorRuntime
    private val sending = AtomicBoolean(false)
    private val refreshing = AtomicBoolean(false)
    private lateinit var senderInstance: String
    private var senderGeneration = 0L
    private var statusSequence = 0L
    private const val COMMAND = "/collector/v1/command"
    fun init(context: Context) {
        this.context = context.applicationContext
        val prefs = runtime.prefs
        senderInstance = prefs.getString("sender_installation", null) ?: UUID.randomUUID().toString()
        senderGeneration = prefs.getLong("sender_generation", 0) + 1
        // Persist before sending any status, so delayed packets from an older process stay older.
        prefs.edit().putString("sender_installation", senderInstance).putLong("sender_generation", senderGeneration).commit()
    }
    private fun envelope(type: String) = JSONObject().put("version", 1).put("role", runtime.role).put("type", type)
    private fun send(node: String, json: JSONObject) {
        Wearable.getMessageClient(context).sendMessage(node, COMMAND, json.toString().toByteArray())
            .addOnFailureListener { runtime.peerState = "Unreachable" }
    }
    private fun toPeer(json: JSONObject) { runtime.peerId?.let { send(it, json) } }
    fun refresh() {
        if (!refreshing.compareAndSet(false, true)) return
        val capability = if (CaptureFactory.isWear) "collector_phone" else "collector_watch"
        Wearable.getCapabilityClient(context).getCapability(capability, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { info ->
                val nodes = info.nodes
                if (nodes.size == 1) {
                    runtime.peerId = nodes.first().id
                    send(nodes.first().id, envelope("hello"))
                } else {
                    runtime.peerId = null
                    if (nodes.size > 1) runtime.peerDetail = "Multiple companions; disconnect extras"
                }
            }.addOnCompleteListener { refreshing.set(false) }
    }
    fun sendStatus(node: String? = runtime.peerId) {
        node ?: return
        send(node, envelope("status").put("sender_instance", senderInstance).put("generation", senderGeneration).put("sequence", ++statusSequence).put("phase", runtime.state.phase.name).put("session_id", runtime.state.session?.id ?: "")
            .put("detail", runtime.detail))
    }
    fun sendStart(spec: SessionSpec) { toPeer(envelope("start").put("session", spec.json())) }
    fun sendStop(id: String) {
        val pending = runtime.prefs.getStringSet("pending_stops", emptySet())!!.toMutableSet(); pending.add(id)
        runtime.prefs.edit().putStringSet("pending_stops", pending.toList().takeLast(256).toSet()).apply()
        toPeer(envelope("stop").put("session_id", id))
    }
    fun resendStops(node: String) {
        runtime.prefs.getStringSet("pending_stops", emptySet())!!.forEach { send(node, envelope("stop").put("session_id", it)) }
    }
    fun acknowledgeStop(node: String, id: String) { send(node, envelope("stop_ack").put("session_id", id)) }
    fun reject(node: String, spec: SessionSpec, reason: String) { send(node, envelope("reject").put("session_id", spec.id).put("reason", reason)) }
    fun suffix(suffix: String) { toPeer(envelope("suffix").put("suffix", suffix)) }
    fun retry() { if (CaptureFactory.isWear) queueFiles(true) else toPeer(envelope("retry")) }

    /** Stable, finalized files only. ACK is a separate DataItem and never deletes the source. */
    fun queueFiles(manual: Boolean = false) {
        if (!CaptureFactory.isWear || !sending.compareAndSet(false, true)) return
        io.execute {
            try {
                var queued = 0
                runtime.root.listFiles()?.filter { File(it, ".closed-watch").exists() }?.forEach { dir ->
                    dir.listFiles()?.filter { it.isFile && !it.name.startsWith('.') }?.forEach { file ->
                        val receipt = File(dir, ".receipt-${file.name}")
                        if (!manual && receipt.exists()) return@forEach
                        val sha = Integrity.sha256(file)
                        val request = PutDataMapRequest.create("/collector/v1/file/${dir.name}/${file.name}")
                        request.dataMap.putString("session_id", dir.name)
                        request.dataMap.putString("filename", file.name)
                        request.dataMap.putString("sha256", sha)
                        request.dataMap.putLong("size", file.length())
                        request.dataMap.putLong("retry", if (manual) System.currentTimeMillis() else 0)
                        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                            request.dataMap.putAsset("body", Asset.createFromFd(fd))
                            Tasks.await(Wearable.getDataClient(context).putDataItem(request.asPutDataRequest().setUrgent()), 90, TimeUnit.SECONDS)
                        }
                        queued++
                    }
                }
                runtime.transferStatus = if (queued > 0) "$queued files queued · originals retained" else "All closed files already receipted"
            } catch (e: Exception) { reportTransferIssue("Transfer pending · check pairing and retry", e) }
            finally { sending.set(false) }
        }
    }
    fun reportTransferIssue(summary: String, error: Throwable? = null) {
        runtime.transferStatus = summary
        runtime.prefs.edit().putString("last_transfer_error", error?.toString() ?: summary).apply()
        if (error != null) android.util.Log.w("CollectorTransfer", summary, error)
    }
    fun onData(item: DataItem): Future<*>? {
        val path = item.uri.path ?: return null
        val data = DataMapItem.fromDataItem(item).dataMap
        // Copy primitives before the event buffer closes; Asset is an independent value object.
        val id = data.getString("session_id") ?: return null
        val name = data.getString("filename") ?: return null
        val hash = data.getString("sha256") ?: return null
        val size = data.getLong("size")
        val uuidValid = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
        if (!uuidValid || !Integrity.safeName(name)) return null
        return if (path.startsWith("/collector/v1/file/") && !CaptureFactory.isWear) {
            val asset = data.getAsset("body") ?: return null
            io.submit {
                try {
                    val response = Tasks.await(Wearable.getDataClient(context).getFdForAsset(asset), 90, TimeUnit.SECONDS)
                    val destination = File(File(runtime.root, id), name)
                    try { response.inputStream.use { input -> Integrity.receive(input, destination, size, hash) } } finally { response.release() }
                    val receipt = PutDataMapRequest.create("/collector/v1/receipt/$id/$name")
                    receipt.dataMap.putString("session_id", id); receipt.dataMap.putString("filename", name)
                    receipt.dataMap.putString("sha256", hash); receipt.dataMap.putLong("size", size)
                    receipt.dataMap.putLong("verified_epoch_ms", System.currentTimeMillis())
                    receipt.dataMap.putString("receipt_nonce", UUID.randomUUID().toString())
                    Tasks.await(Wearable.getDataClient(context).putDataItem(receipt.asPutDataRequest().setUrgent()), 30, TimeUnit.SECONDS)
                    runtime.transferStatus = "Received & verified: $name"
                } catch (e: Exception) { reportTransferIssue("File receipt failed · original retained; retry", e) }
            }
        } else if (path.startsWith("/collector/v1/receipt/") && CaptureFactory.isWear) {
            io.submit {
                val dir = File(runtime.root, id); val file = File(dir, name)
                runCatching {
                    if (File(dir, ".closed-watch").exists() && file.exists() && file.length() == size && Integrity.sha256(file) == hash) {
                        File(dir, ".receipt-$name").writeText(hash)
                        runtime.transferStatus = "Phone verified $name · local copy retained"
                        // Only remove the replicated transport asset after durable verified phone receipt.
                        val localNode = Tasks.await(Wearable.getNodeClient(context).localNode, 30, TimeUnit.SECONDS)
                        val uri = android.net.Uri.Builder().scheme("wear").authority(localNode.id).path("/collector/v1/file/$id/$name").build()
                        val deleted = Tasks.await(Wearable.getDataClient(context).deleteDataItems(uri, DataClient.FILTER_LITERAL), 30, TimeUnit.SECONDS)
                        if (deleted == 0) runtime.transferStatus = "Phone verified $name · transport already clear"
                    }
                }.onFailure { reportTransferIssue("Receipt check failed · original retained", it) }
            }
        } else null
    }
    fun scanPending() {
        Wearable.getDataClient(context).dataItems.addOnSuccessListener { items ->
            try { items.forEach { onData(it) } } finally { items.release() }
        }
    }
}

class LinkListener : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path == "/collector/v1/command" && event.data.size <= 8192)
            CollectorRuntime.main.post { CollectorRuntime.acceptMessage(event.sourceNodeId, String(event.data, Charsets.UTF_8)) }
    }
}

/** Separate service/default background looper keeps file waits away from Start/Stop messages. */
class FileListener : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        // Capture independent values before this buffer closes. The service's default
        // callback looper is a background thread; scanPending never performs this wait.
        val pending = events.mapNotNull { event ->
            if (event.type != DataEvent.TYPE_CHANGED) null
            else runCatching { Link.onData(event.dataItem) }
                .onFailure { Link.reportTransferIssue("Invalid transfer event · original retained", it) }
                .getOrNull()
        }
        for (task in pending) {
            try {
                // Keep the listener callback alive through bounded verification/ACK work.
                task.get(150, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                CollectorRuntime.transferStatus = "Transfer interrupted · original retained; reopen or Retry"
                return
            } catch (_: TimeoutException) {
                // Do not cancel a file operation midway; persistent items can be scanned again.
                CollectorRuntime.transferStatus = "Transfer still pending · original retained; reopen or Retry"
            } catch (error: ExecutionException) {
                Link.reportTransferIssue("Transfer failed · original retained; retry", error.cause ?: error)
            }
        }
    }
}
