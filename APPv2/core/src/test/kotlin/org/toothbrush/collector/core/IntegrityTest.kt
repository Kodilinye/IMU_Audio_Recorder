package org.toothbrush.collector.core

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class IntegrityTest {
    @get:Rule val folder = TemporaryFolder()

    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun noTemporaryFiles() {
        assertTrue(folder.root.walkTopDown().none { it.isFile && it.name.endsWith(".part") })
    }

    @Test fun successfulReceiptPreservesAllBytesAcrossCopyBufferBoundaries() {
        val bytes = ByteArray(196_777) { ((it * 71 + it / 251) and 255).toByte() }
        val destination = File(folder.root, "session/motion.csv")
        val received = Integrity.receive(ByteArrayInputStream(bytes), destination, bytes.size.toLong(), digest(bytes))
        assertEquals(destination, received)
        assertArrayEquals(bytes, destination.readBytes())
        assertEquals(digest(bytes), Integrity.sha256(destination))
        noTemporaryFiles()
    }

    @Test fun truncatedOversizedAndCorruptTransfersNeverPublishAReceiptFile() {
        val expected = "scientific recording".toByteArray()
        val cases = listOf(expected.copyOf(expected.size - 1), expected + byteArrayOf(0), "incorrect recording!".toByteArray())
        for ((index, actual) in cases.withIndex()) {
            val destination = File(folder.root, "recording_$index.csv")
            assertThrows(IllegalArgumentException::class.java) {
                Integrity.receive(ByteArrayInputStream(actual), destination, expected.size.toLong(), digest(expected))
            }
            assertFalse(destination.exists())
            noTemporaryFiles()
        }
    }

    @Test fun equalLengthChecksumCorruptionIsRejectedAndTemporaryBytesAreRemoved() {
        val expected = byteArrayOf(1, 2, 3, 4)
        val destination = File(folder.root, "audio.wav")
        val failure = assertThrows(IllegalArgumentException::class.java) {
            Integrity.receive(ByteArrayInputStream(byteArrayOf(1, 2, 3, 5)), destination, 4, digest(expected))
        }
        assertEquals("Checksum mismatch", failure.message)
        assertFalse(destination.exists())
        noTemporaryFiles()
    }

    @Test fun existingConflictingFileIsNeverReplaced() {
        val destination = folder.newFile("metadata.json")
        val original = "old immutable session".toByteArray()
        val different = "new immutable session".toByteArray()
        destination.writeBytes(original)
        assertThrows(IllegalStateException::class.java) {
            Integrity.receive(ByteArrayInputStream(different), destination, different.size.toLong(), digest(different))
        }
        assertArrayEquals(original, destination.readBytes())
        noTemporaryFiles()
    }

    @Test fun duplicateReceiptIsIdempotentAndDoesNotReplaceVerifiedDestination() {
        val bytes = "same verified source".toByteArray()
        val destination = File(folder.root, "motion.csv")
        repeat(2) {
            Integrity.receive(ByteArrayInputStream(bytes), destination, bytes.size.toLong(), digest(bytes))
            assertArrayEquals(bytes, destination.readBytes())
            noTemporaryFiles()
            if (it == 0) assertTrue(destination.setLastModified(1_600_000_000_000L))
        }
        assertEquals(1_600_000_000_000L, destination.lastModified())
    }

    @Test fun interruptedReadCleansTemporaryFileAndPreservesExistingDestination() {
        val destination = folder.newFile("audio.wav")
        val original = byteArrayOf(1, 2, 3, 4)
        destination.writeBytes(original)
        val broken = object : InputStream() {
            private var count = 0
            override fun read(): Int = if (count++ < 2) 9 else throw IOException("link disconnected")
        }
        assertThrows(IOException::class.java) { Integrity.receive(broken, destination, 4, digest(original)) }
        assertArrayEquals(original, destination.readBytes())
        noTemporaryFiles()
    }

    @Test fun emptyFileIsVerifiedAndUnsafeNamesOrManifestsAreRejected() {
        val empty = File(folder.root, "empty.csv")
        Integrity.receive(ByteArrayInputStream(byteArrayOf()), empty, 0, digest(byteArrayOf()))
        assertEquals(0, empty.length())
        for (name in listOf("", ".", "..", ".hidden", "../motion.csv", "a/b", "a\\b", "bad\u0000name")) {
            assertFalse(name, Integrity.safeName(name))
        }
        assertTrue(Integrity.safeName("motion_20260928_120000_participant.csv"))
        val output = File(folder.root, "invalid.csv")
        assertThrows(IllegalArgumentException::class.java) {
            Integrity.receive(ByteArrayInputStream(byteArrayOf()), output, -1, digest(byteArrayOf()))
        }
        assertThrows(IllegalArgumentException::class.java) {
            Integrity.receive(ByteArrayInputStream(byteArrayOf()), output, 0, "not-a-digest")
        }
        assertFalse(output.exists())
        noTemporaryFiles()
    }
}
