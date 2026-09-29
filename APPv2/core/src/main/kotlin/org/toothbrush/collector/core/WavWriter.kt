package org.toothbrush.collector.core

import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile

/** PCM16 little endian, with a valid header even for zero frames. Never truncates existing data. */
class WavWriter(file: File, val sampleRate: Int, val channels: Int = 1) : Closeable {
    private val out: RandomAccessFile
    private var bytes = 0L
    private var closed = false
    init {
        require(sampleRate > 0 && channels in 1..2)
        check(file.createNewFile()) { "File already exists: ${file.name}" }
        out = RandomAccessFile(file, "rw")
        header(); out.seek(44)
    }
    @Synchronized fun write(data: ByteArray, count: Int) {
        check(!closed); require(count in 0..data.size && count % (channels * 2) == 0)
        check(bytes + count <= 0xffffffffL - 36) { "WAV size limit" }
        out.write(data, 0, count); bytes += count
    }
    private fun le(value: Long, n: Int) { repeat(n) { out.write((value ushr (it * 8)).toInt() and 255) } }
    private fun header() {
        out.seek(0); out.writeBytes("RIFF"); le(36 + bytes, 4); out.writeBytes("WAVEfmt "); le(16, 4)
        le(1, 2); le(channels.toLong(), 2); le(sampleRate.toLong(), 4); le((sampleRate * channels * 2).toLong(), 4)
        le((channels * 2).toLong(), 2); le(16, 2); out.writeBytes("data"); le(bytes, 4)
    }
    @Synchronized override fun close() {
        if (closed) return
        try { header(); out.fd.sync() } finally { closed = true; out.close() }
    }
    companion object {
        /** Recover complete PCM frames after process death, retaining the recorded bytes. */
        fun recover(file: File) {
            RandomAccessFile(file, "rw").use { f ->
                require(f.length() >= 44)
                val riff = ByteArray(4); f.readFully(riff); require(String(riff) == "RIFF")
                f.seek(32); val align = f.read() or (f.read() shl 8); require(align in 2..4)
                val size = (f.length() - 44) / align * align
                require(size <= 0xffffffffL - 36)
                f.setLength(size + 44)
                fun put(at: Long, n: Long) { f.seek(at); repeat(4) { f.write((n ushr (it * 8)).toInt() and 255) } }
                put(4, size + 36); put(40, size); f.fd.sync()
            }
        }
    }
}
