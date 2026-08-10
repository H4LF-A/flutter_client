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

  // DISABLED: every write strategy tried (per-band limiter, cross-band-
  // uniform limiter, band-0-only) produced the same reported distortion at
  // any non-unity gain, while leaving the buffer untouched was consistently
  // clean - see the class doc. process() is now read-only regardless of
  // the requested gain; these tests lock that in.

  @Test
  fun `buffer is never modified regardless of requested gain`() {
    for (gain in listOf(0.0, 0.05, 0.5, 1.0, 1.5, 2.0, 4.0)) {
      val processor = GainAudioProcessor()
      processor.setGain(gain)
      val original = fullFrame(1000, -2000, 16000, -16000, 32000, -32000)
      val buffer = bufferOf(original)
      processor.process(NUM_BANDS, NUM_FRAMES, buffer)
      assertTrue(
        original.contentEquals(readShorts(buffer, original.size)),
        "buffer must be unchanged at gain=$gain",
      )
    }
  }

  @Test
  fun `lastRequestedGain reports the last setGain value without applying it`() {
    val processor = GainAudioProcessor()
    processor.setGain(0.5)
    assertEquals(0.5, processor.lastRequestedGain, 0.001)
    val original = fullFrame(10000, -10000)
    val buffer = bufferOf(original)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    assertTrue(original.contentEquals(readShorts(buffer, original.size)))
    assertEquals(0.5, processor.lastRequestedGain, 0.001)
  }

  @Test
  fun `peak and band RMS diagnostics still reflect the real captured signal`() {
    val processor = GainAudioProcessor()
    processor.setGain(2.0) // must have no bearing on the diagnostics below
    val samples = ShortArray(NUM_BANDS * NUM_FRAMES)
    samples[0] = 10000 // band 0
    samples[NUM_FRAMES] = 20000 // band 1
    val buffer = bufferOf(samples)
    processor.process(NUM_BANDS, NUM_FRAMES, buffer)
    assertEquals(20000, processor.lastPeakBeforeGain)
    assertEquals(20000, processor.lastPeakAfterGain, "no gain is applied, so before/after must match")
    assertEquals(3, processor.lastBandRms.size)
    assertTrue(processor.lastBandRms[1] > processor.lastBandRms[0], "band 1 carries more energy in this fixture")
  }

  @Test
  fun `only one instance exists per construction`() {
    val a = GainAudioProcessor()
    val b = GainAudioProcessor()
    assertTrue(a.instanceId != b.instanceId, "distinct instances must report distinct ids")
  }
}
