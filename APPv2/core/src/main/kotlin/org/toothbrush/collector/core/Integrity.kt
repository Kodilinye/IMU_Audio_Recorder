package org.toothbrush.collector.core

import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest

object Integrity {
    fun sha256(file: File): String = file.inputStream().use { input ->
        val digest = MessageDigest.getInstance("SHA-256"); val buffer = ByteArray(65536)
        while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    fun safeName(name: String): Boolean = name.isNotBlank() && name.length <= 180 && name != "." && name != ".." &&
        name.none { it == '/' || it == '\\' || it.code < 32 } && !name.startsWith('.')
    /** Returns only after durable bytes, size and SHA agree. Existing different bytes are never replaced. */
    @Synchronized fun receive(input: InputStream, destination: File, expectedSize: Long, expectedHash: String): File {
        require(safeName(destination.name) && expectedSize in 0..(4L * 1024 * 1024 * 1024))
        require(expectedHash.matches(Regex("[a-f0-9]{64}")))
        destination.parentFile.mkdirs()
        val temp = File.createTempFile(".receive-", ".part", destination.parentFile)
        try {
            FileOutputStream(temp).use { out ->
                val buffer = ByteArray(65536); var total = 0L
                while (true) { val n = input.read(buffer); if (n < 0) break; total += n; require(total <= expectedSize) { "Oversize transfer" }; out.write(buffer, 0, n) }
                require(total == expectedSize) { "Truncated transfer" }; out.fd.sync()
            }
            require(sha256(temp) == expectedHash) { "Checksum mismatch" }
            if (destination.exists()) {
                check(destination.length() == expectedSize && sha256(destination) == expectedHash) { "Conflicting destination" }
            } else check(temp.renameTo(destination)) { "Cannot publish received file" }
            return destination
        } finally { temp.delete() }
    }
}
