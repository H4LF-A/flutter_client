package io.livekit.plugin

import java.nio.ByteBuffer
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
    // Deliberately does not set the buffer's order - PcmBuffer must not
    // depend on it, matching how WebRTC hands buffers to this hook.
    val buffer = ByteBuffer.allocateDirect(samples.size * 2)
    for ((i, sample) in samples.withIndex()) {
      PcmBuffer.writeSampleLE(buffer, i * 2, sample.toInt())
    }
    return buffer
  }

  private fun readSamples(buffer: ByteBuffer, count: Int): IntArray =
    IntArray(count) { PcmBuffer.readSampleLE(buffer, it * 2) }

  private fun fullFrame(vararg firstSamples: Int): IntArray {
    val samples = IntArray(NUM_BANDS * NUM_FRAMES)
    for (i in firstSamples.indices) {
      samples[i] = firstSamples[i]
    }
    return samples
  }

  private fun bufferOfInts(samples: IntArray): ByteBuffer {
    val buffer = ByteBuffer.allocateDirect(samples.size * 2)
    for ((i, sample) in samples.withIndex()) {
      PcmBuffer.writeSampleLE(buffer, i * 2, sample)
    }
    return buffer
  }

  @Test
  fun `unity gain leaves samples unchanged`() {
    val processor = GainAudioProcessor()
    val original = fullFrame(1000, -2000, 16000, -16000)
    val buffer = bufferOfInts(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    assertTrue(original.contentEquals(readSamples(buffer, original.size)))
  }

  @Test
  fun `5 percent gain quiets band 0 instead of amplifying it`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.05)
    val original = fullFrame(10000, -10000, 20000, -20000)
    val buffer = bufferOfInts(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readSamples(buffer, original.size)
    // Only the first 4 samples are nonzero (see fullFrame, all within band
    // 0 since NUM_FRAMES=480); the rest are zero-padding.
    for (i in 0 until 4) {
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
  fun `0 percent gain silences band 0`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.0)
    val original = fullFrame(12345, -12345, 32000, -32000)
    val buffer = bufferOfInts(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readSamples(buffer, original.size)
    for (i in 0 until 4) {
      assertEquals(0, result[i])
    }
  }

  @Test
  fun `95-105 percent gain scales band 0 roughly linearly`() {
    val original = fullFrame(10000, -10000)
    for (percent in listOf(0.95, 0.97, 1.0, 1.03, 1.05)) {
      val processor = GainAudioProcessor()
      processor.setGain(percent)
      val buffer = bufferOfInts(original)
      processor.process(NUM_BANDS, NUM_FRAMES, buffer)
      val result = readSamples(buffer, original.size)
      val expected0 = (original[0] * percent).toInt()
      assertTrue(
        kotlin.math.abs(result[0] - expected0) <= 2,
        "gain=$percent sample0: expected ~$expected0, got ${result[0]}",
      )
    }
  }

  @Test
  fun `200 percent gain roughly doubles a quiet band 0 signal`() {
    val processor = GainAudioProcessor()
    processor.setGain(2.0)
    val original = fullFrame(5000, -5000)
    val buffer = bufferOfInts(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readSamples(buffer, original.size)
    assertTrue(kotlin.math.abs(result[0] - 10000) <= 2, "expected ~10000, got ${result[0]}")
    assertTrue(kotlin.math.abs(result[1] - -10000) <= 2, "expected ~-10000, got ${result[1]}")
  }

  @Test
  fun `200 percent gain on a loud band 0 signal is limited, not hard-clipped or wrapped`() {
    val processor = GainAudioProcessor()
    processor.setGain(2.0)
    // 20000 * 2.0 = 40000, overflows Int16 - the shape that would expose a
    // hard-clamp/overflow/wraparound bug as "crazy high volume".
    val original = fullFrame(20000, -20000)
    val buffer = bufferOfInts(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readSamples(buffer, original.size)
    assertTrue(result[0] in 20000..32767, "expected a loud but valid sample, got ${result[0]}")
    assertTrue(result[1] in -32768..-20000, "expected a loud but valid sample, got ${result[1]}")
  }

  @Test
  fun `gain only touches band 0, bands 1 and 2 are left untouched`() {
    // Band 1 carries substantial real energy on real devices (confirmed via
    // the on-device bandRms diagnostic) - not simple duplicate/parallel
    // content safe to rewrite the way band 0 is, so only band 0 is scaled.
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    val samples = IntArray(NUM_BANDS * NUM_FRAMES)
    samples[0] = 10000
    samples[NUM_FRAMES] = 20000
    samples[NUM_FRAMES * 2] = 30000
    val buffer = bufferOfInts(samples)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    val result = readSamples(buffer, samples.size)
    assertEquals(5000, result[0])
    assertEquals(20000, result[NUM_FRAMES], "band 1 must be left untouched")
    assertEquals(30000, result[NUM_FRAMES * 2], "band 2 must be left untouched")
  }

  @Test
  fun `process never calls buffer order (stays independent of it)`() {
    // A stronger version of the above tests: construct the buffer at its
    // default order and confirm process() neither depends on it nor
    // changes it - the exact property change implicated in the earlier
    // confirmed-on-remote-listener distortion.
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    val buffer = ByteBuffer.allocateDirect(NUM_BANDS * NUM_FRAMES * 2)
    PcmBuffer.writeSampleLE(buffer, 0, 10000)
    val orderBefore = buffer.order()
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    assertEquals(orderBefore, buffer.order(), "process() must not mutate buffer.order()")
    assertEquals(5000, PcmBuffer.readSampleLE(buffer, 0))
  }
}
