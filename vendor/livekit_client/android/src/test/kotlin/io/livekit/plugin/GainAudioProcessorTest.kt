package io.livekit.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class GainAudioProcessorTest {

  companion object {
    // Matches the real shape confirmed on-device: 3 bands, 480 frames each.
    private const val NUM_BANDS = 3
    private const val NUM_FRAMES = 480
  }

  private fun bufferOf(samples: ShortArray): ByteBuffer {
    val buffer = ByteBuffer.allocateDirect(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
    for (sample in samples) {
      buffer.putShort(sample)
    }
    buffer.flip()
    return buffer
  }

  private fun readShorts(buffer: ByteBuffer, count: Int): ShortArray {
    val order = buffer.order()
    buffer.order(ByteOrder.LITTLE_ENDIAN)
    val out = ShortArray(count) { buffer.getShort(it * 2) }
    buffer.order(order)
    return out
  }

  private fun fullFrame(vararg firstSamples: Short): ShortArray {
    val samples = ShortArray(NUM_BANDS * NUM_FRAMES)
    for (i in firstSamples.indices) {
      samples[i] = firstSamples[i]
    }
    return samples
  }

  @Test
  fun `unity gain leaves samples unchanged`() {
    val processor = GainAudioProcessor()
    val original = fullFrame(1000, -2000, 16000, -16000)
    val buffer = bufferOf(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    assertTrue(original.contentEquals(readShorts(buffer, original.size)))
  }

  @Test
  fun `5 percent gain quiets the signal instead of amplifying it`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.05)
    val original = fullFrame(10000, -10000, 20000, -20000)
    val buffer = bufferOf(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readShorts(buffer, original.size)
    // Only the first 4 samples are nonzero (see fullFrame); the rest are
    // zero-padding and would trivially satisfy/fail a "quieter than" check.
    for (i in 0 until 4) {
      val expected = (original[i] * 0.05).toInt()
      // Allow rounding slack, but the defining property under test is that
      // the output is roughly 5% of the input, not anywhere near full scale
      // ("crazy high volume") - this is what the user reported as broken.
      assertTrue(
        kotlin.math.abs(result[i] - expected) <= 2,
        "sample $i: expected ~$expected, got ${result[i]} (original ${original[i]})",
      )
      assertTrue(
        kotlin.math.abs(result[i].toInt()) < kotlin.math.abs(original[i].toInt()),
        "sample $i: 5% gain must quiet the signal, got ${result[i]} from ${original[i]}",
      )
    }
  }

  @Test
  fun `0 percent gain silences the signal`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.0)
    val original = fullFrame(12345, -12345, 32000, -32000)
    val buffer = bufferOf(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readShorts(buffer, original.size)
    for (sample in result) {
      assertEquals(0, sample.toInt())
    }
  }

  @Test
  fun `100 percent adjacent values (95-105pct) scale roughly linearly`() {
    val original = fullFrame(10000, -10000)
    for (percent in listOf(0.95, 0.97, 1.0, 1.03, 1.05)) {
      val processor = GainAudioProcessor()
      processor.setGain(percent)
      val buffer = bufferOf(original)
      processor.process(NUM_BANDS, NUM_FRAMES, buffer)
      val result = readShorts(buffer, original.size)
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
    // Deliberately quiet input so doubling it doesn't need the limiter,
    // isolating "does the multiply itself work" from "does the limiter work".
    val original = fullFrame(5000, -5000)
    val buffer = bufferOf(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readShorts(buffer, original.size)
    assertTrue(
      kotlin.math.abs(result[0] - 10000) <= 2,
      "expected ~10000, got ${result[0]}",
    )
    assertTrue(
      kotlin.math.abs(result[1] - -10000) <= 2,
      "expected ~-10000, got ${result[1]}",
    )
  }

  @Test
  fun `200 percent gain on a loud signal is limited, not hard-clipped or wrapped`() {
    val processor = GainAudioProcessor()
    processor.setGain(2.0)
    // 20000 * 2.0 = 40000, which overflows Short - this is exactly the shape
    // of input that would expose a hard-clamp/overflow/wraparound bug as
    // "crazy high volume" (e.g. wrapping to a small negative or garbage
    // value instead of a sane loud one).
    val original = fullFrame(20000, -20000)
    val buffer = bufferOf(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readShorts(buffer, original.size)
    assertTrue(result[0] in 20000..32767, "expected a loud but valid sample, got ${result[0]}")
    assertTrue(result[1] in -32768..-20000, "expected a loud but valid sample, got ${result[1]}")
  }

  @Test
  fun `EXPERIMENT gain only touches band 0, bands 1 and 2 are left untouched`() {
    // Reported "ear-raping" distortion at non-unity gain survived every
    // other explanation tried (feedback, AGC, duplicate processing, audio
    // source) and correlated only with "does this code modify the buffer
    // at all" - band 1 carries substantial real energy (confirmed via the
    // on-device bandRms diagnostic) and may not be simple parallel audio
    // content safe to rewrite the way band 0 (already proven safe, since
    // DeepFilterNoiseProcessor has processed only band 0 all along without
    // this symptom) is. This locks in the experiment: only band 0 changes.
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    val samples = ShortArray(NUM_BANDS * NUM_FRAMES)
    samples[0] = 10000
    samples[NUM_FRAMES] = 20000
    samples[NUM_FRAMES * 2] = 30000
    val buffer = bufferOf(samples)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readShorts(buffer, samples.size)
    assertEquals(5000, result[0].toInt())
    assertEquals(20000, result[NUM_FRAMES].toInt(), "band 1 must be left untouched")
    assertEquals(30000, result[NUM_FRAMES * 2].toInt(), "band 2 must be left untouched")
  }
}
