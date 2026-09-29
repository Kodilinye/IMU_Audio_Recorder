package org.toothbrush.collector.core

/** A retired sender installation/process generation cannot overwrite fresh status after reconnection. */
class StatusOrder {
    private data class Cursor(var incarnation: String, var sequence: Long, var generation: Long, val retired: MutableSet<String> = mutableSetOf())
    private val peers = mutableMapOf<String, Cursor>()
    fun accept(node: String, incarnation: String, sequence: Long, generation: Long = 0): Boolean {
        if (sequence <= 0 || incarnation.isBlank() || generation < 0) return false
        val cursor = peers[node]
        if (cursor == null) { peers[node] = Cursor(incarnation, sequence, generation); return true }
        if (incarnation in cursor.retired) return false
        if (incarnation == cursor.incarnation) {
            if (generation < cursor.generation) return false
            if (generation > cursor.generation) { cursor.generation = generation; cursor.sequence = sequence; return true }
            if (sequence <= cursor.sequence) return false
            cursor.sequence = sequence; return true
        }
        cursor.retired.add(cursor.incarnation)
        cursor.incarnation = incarnation; cursor.sequence = sequence; cursor.generation = generation
        return true
    }
}
