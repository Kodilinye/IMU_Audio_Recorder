package org.toothbrush.collector.core

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WavWriterTest {
    @get:Rule val folder = TemporaryFolder()

    private fun unsignedInt(bytes: ByteArray, offset: Int): Long =
        ByteBuffer.wrap(bytes, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL

    private fun header(file: File, rate: Int, channels: Int, dataBytes: Int) {
        val bytes = file.readBytes()
        assertEquals(44 + dataBytes, bytes.size)
        assertEquals("RIFF", String(bytes.copyOfRange(0, 4), Charsets.US_ASCII))
        assertEquals("WAVEfmt ", String(bytes.copyOfRange(8, 16), Charsets.US_ASCII))
        assertEquals("data", String(bytes.copyOfRange(36, 40), Charsets.US_ASCII))
        assertEquals((36 + dataBytes).toLong(), unsignedInt(bytes, 4))
        assertEquals(16L, unsignedInt(bytes, 16))
        assertEquals(1, ByteBuffer.wrap(bytes, 20, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt())
        assertEquals(channels, ByteBuffer.wrap(bytes, 22, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt())
        assertEquals(rate.toLong(), unsignedInt(bytes, 24))
        assertEquals((rate * channels * 2).toLong(), unsignedInt(bytes, 28))
        assertEquals(channels * 2, ByteBuffer.wrap(bytes, 32, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt())
        assertEquals(16, ByteBuffer.wrap(bytes, 34, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt())
        assertEquals(dataBytes.toLong(), unsignedInt(bytes, 40))
    }

    @Test fun zeroFramesStillProduceAValidPcmWave() {
        val file = File(folder.root, "zero.wav")
        WavWriter(file, 44_100).use { writer -> writer.write(byteArrayOf(), 0) }
        header(file, 44_100, 1, 0)
    }

    @Test fun firstAndLastPcmFramesSurviveHeaderRewriteAndRepeatedClose() {
        val file = File(folder.root, "samples.wav")
        val first = byteArrayOf(0x34, 0x12, 0, 0x80.toByte())
        val last = byteArrayOf(0xff.toByte(), 0x7f, 0x55, 0x01)
        val writer = WavWriter(file, 48_000)
        writer.write(first, first.size)
        writer.write(last, last.size)
        writer.close()
        val closed = file.readBytes()
        writer.close()
        assertArrayEquals(closed, file.readBytes())
        header(file, 48_000, 1, 8)
        assertArrayEquals(first + last, closed.copyOfRange(44, closed.size))
        assertThrows(IllegalStateException::class.java) { writer.write(first, first.size) }
    }

    @Test fun refuseExistingFileAndMisalignedPcmWithoutDamagingExistingData() {
        val existing = folder.newFile("original.wav")
        val original = byteArrayOf(1, 2, 3, 4)
        existing.writeBytes(original)
        assertThrows(IllegalStateException::class.java) { WavWriter(existing, 44_100) }
        assertArrayEquals(original, existing.readBytes())
        val stereo = File(folder.root, "stereo.wav")
        WavWriter(stereo, 48_000, 2).use { writer ->
            assertThrows(IllegalArgumentException::class.java) { writer.write(byteArrayOf(1, 2), 2) }
            assertThrows(IllegalArgumentException::class.java) { writer.write(byteArrayOf(1, 2, 3, 4), 8) }
            writer.write(byteArrayOf(1, 2, 3, 4), 4)
        }
        header(stereo, 48_000, 2, 4)
    }

    @Test fun recoverInterruptedPcmKeepsCompleteFramesAndDiscardsOnlyPartialTail() {
        val file = File(folder.root, "interrupted.wav")
        WavWriter(file, 44_100, 2).close()
        // Simulate death after PCM append but before updating the zero-length header.
        val bytes = byteArrayOf(0x34, 0x12, 0x78, 0x56, 9, 10, 11)
        FileOutputStream(file, true).use { it.write(bytes) }
        WavWriter.recover(file)
        header(file, 44_100, 2, 4)
        assertArrayEquals(bytes.copyOfRange(0, 4), file.readBytes().copyOfRange(44, 48))
        val recovered = file.readBytes()
        WavWriter.recover(file)
        assertArrayEquals(recovered, file.readBytes())
    }
}
