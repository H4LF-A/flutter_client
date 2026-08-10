package io.livekit.plugin

import android.media.AudioFormat
import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class GainAudioProcessorTest {

  companion object {
    private const val SAMPLE_RATE = 48000
    private const val CHANNELS = 1
  }

  private fun bufferOf(samples: IntArray): ByteBuffer {
    // Deliberately does not set the buffer's order - PcmBuffer must not
    // depend on it, matching how the AudioBufferCallback hook hands
    // buffers to this processor.
    val buffer = ByteBuffer.allocateDirect(samples.size * 2)
    for ((i, sample) in samples.withIndex()) {
      PcmBuffer.writeSampleLE(buffer, i * 2, sample)
    }
    return buffer
  }

  private fun readSamples(buffer: ByteBuffer, count: Int): IntArray =
    IntArray(count) { PcmBuffer.readSampleLE(buffer, it * 2) }

  private fun process(processor: GainAudioProcessor, samples: IntArray): IntArray {
    val buffer = bufferOf(samples)
    processor.process(buffer, AudioFormat.ENCODING_PCM_16BIT, CHANNELS, SAMPLE_RATE, samples.size * 2)
    return readSamples(buffer, samples.size)
  }

  @Test
  fun `unity gain leaves samples unchanged`() {
    val processor = GainAudioProcessor()
    val original = intArrayOf(1000, -2000, 16000, -16000)
    assertTrue(original.contentEquals(process(processor, original)))
  }

  @Test
  fun `5 percent gain quiets the signal instead of amplifying it`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.05)
    val original = intArrayOf(10000, -10000, 20000, -20000)
    val result = process(processor, original)
    for (i in original.indices) {
      val expected = (original[i] * 0.05).toInt()
      assertTrue(
        kotlin.math.abs(result[i] - expected) <= 2,
        "sample $i: expected ~$expected, got ${result[i]} (original ${original[i]})",
      )
      assertTrue(
        kotlin.math.abs(result[i]) < kotlin.math.abs(original[i]),
        "sample $i: 5% gain must quiet the signal, got ${result[i]} from ${original[i]}",
      )
    }
  }

  @Test
  fun `0 percent gain silences the signal`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.0)
    val result = process(processor, intArrayOf(12345, -12345, 32000, -32000))
    for (sample in result) {
      assertEquals(0, sample)
    }
  }

  @Test
  fun `95-105 percent gain scales roughly linearly`() {
    val original = intArrayOf(10000, -10000)
    for (percent in listOf(0.95, 0.97, 1.0, 1.03, 1.05)) {
      val processor = GainAudioProcessor()
      processor.setGain(percent)
      val result = process(processor, original)
      val expected0 = (original[0] * percent).toInt()
      assertTrue(
        kotlin.math.abs(result[0] - expected0) <= 2,
        "gain=$percent sample0: expected ~$expected0, got ${result[0]}",
      )
    }
  }

  @Test
  fun `200 percent gain roughly doubles a quiet signal without exceeding full scale`() {
    val processor = GainAudioProcessor()
    processor.setGain(2.0)
    val result = process(processor, intArrayOf(5000, -5000))
    assertTrue(kotlin.math.abs(result[0] - 10000) <= 2, "expected ~10000, got ${result[0]}")
    assertTrue(kotlin.math.abs(result[1] - -10000) <= 2, "expected ~-10000, got ${result[1]}")
  }

  @Test
  fun `200 percent gain on a loud signal is limited, not hard-clipped or wrapped`() {
    val processor = GainAudioProcessor()
    processor.setGain(2.0)
    // 20000 * 2.0 = 40000, overflows Int16 - the shape that would expose a
    // hard-clamp/overflow/wraparound bug as "crazy high volume".
    val result = process(processor, intArrayOf(20000, -20000))
    assertTrue(result[0] in 20000..32767, "expected a loud but valid sample, got ${result[0]}")
    assertTrue(result[1] in -32768..-20000, "expected a loud but valid sample, got ${result[1]}")
  }

  @Test
  fun `unsupported audio formats are left untouched`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    val original = intArrayOf(10000, -10000)
    val buffer = bufferOf(original)
    processor.process(buffer, AudioFormat.ENCODING_PCM_FLOAT, CHANNELS, SAMPLE_RATE, original.size * 2)
    assertTrue(original.contentEquals(readSamples(buffer, original.size)))
  }

  @Test
  fun `process never calls buffer order (stays independent of it)`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    val buffer = ByteBuffer.allocateDirect(4)
    PcmBuffer.writeSampleLE(buffer, 0, 10000)
    val orderBefore = buffer.order()
    processor.process(buffer, AudioFormat.ENCODING_PCM_16BIT, CHANNELS, SAMPLE_RATE, 2)
    assertEquals(orderBefore, buffer.order(), "process() must not mutate buffer.order()")
    assertEquals(5000, PcmBuffer.readSampleLE(buffer, 0))
  }

  @Test
  fun `only bytesRead worth of samples are touched, not the whole buffer capacity`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    // Buffer has room for 4 samples, but only the first 2 (bytesRead=4) were
    // actually captured this callback - the rest must be left alone.
    val buffer = ByteBuffer.allocateDirect(8)
    PcmBuffer.writeSampleLE(buffer, 0, 10000)
    PcmBuffer.writeSampleLE(buffer, 2, -10000)
    PcmBuffer.writeSampleLE(buffer, 4, 99999.toShort().toInt()) // untouched sentinel region
    val sentinelBefore = PcmBuffer.readSampleLE(buffer, 4)
    processor.process(buffer, AudioFormat.ENCODING_PCM_16BIT, CHANNELS, SAMPLE_RATE, 4)
    assertEquals(5000, PcmBuffer.readSampleLE(buffer, 0))
    assertEquals(-5000, PcmBuffer.readSampleLE(buffer, 2))
    assertEquals(sentinelBefore, PcmBuffer.readSampleLE(buffer, 4), "bytes beyond bytesRead must be untouched")
  }
}
