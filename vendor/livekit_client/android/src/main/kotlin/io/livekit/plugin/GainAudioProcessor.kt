/*
 * Copyright 2024 LiveKit, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.livekit.plugin

import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

/**
 * Applies a software gain multiplier to the locally captured microphone
 * signal, band 0 only (see PcmBuffer doc for why band 0, not every band).
 * org.webrtc.AudioTrack.setVolume() has no observable effect on Android for
 * local (captured) tracks, so input-volume control happens here instead, in
 * flutter_webrtc's capture-time [AudioProcessingAdapter.ExternalAudioFrameProcessing]
 * hook (the same extension point Krisp's noise filter uses).
 *
 * Reads and writes samples via [PcmBuffer], never touching
 * `ByteBuffer.order()` - see that class's doc for why. Every earlier variant
 * of this class (a per-band limiter, a cross-band-uniform limiter, band-0-
 * only) that instead called `buffer.order(LITTLE_ENDIAN)` before
 * `getShort`/`putShort` produced real distortion confirmed by a remote
 * listener on the actual transmitted audio, while writes with that call
 * removed did not reproduce it. Krisp's own working implementation
 * (`LiveKitKrispNoiseFilter.process`) never touches `buffer.order()` either -
 * it hands the buffer straight to native code.
 */
internal class GainAudioProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
  // Fixed-point (x1000) so the audio-processing thread can read this
  // lock-free without contending with the Dart-triggered setter.
  private val gainMilli = AtomicInteger(UNITY_GAIN_MILLI)

  val lastRequestedGain: Double
    get() = gainMilli.get() / 1000.0

  @Volatile
  var lastSampleRateHz: Int? = null
    private set

  @Volatile
  var lastNumChannels: Int? = null
    private set

  @Volatile
  var lastNumBands: Int? = null
    private set

  @Volatile
  var lastNumFrames: Int? = null
    private set

  @Volatile
  var lastPeakBeforeGain: Int = 0
    private set

  @Volatile
  var lastPeakAfterGain: Int = 0
    private set

  // Per-band RMS of the raw (pre-gain) signal - kept as a diagnostic; band 1
  // carries substantial real energy on real devices, which is exactly why
  // gain (like DeepFilterNoiseProcessor) only ever touches band 0.
  @Volatile
  var lastBandRms: IntArray = IntArray(0)
    private set

  @Volatile
  var lastBufferInfo: String = ""
    private set

  private val processCallCount = AtomicInteger(0)
  private val instanceOrdinal = totalInstancesCreated.incrementAndGet()

  val instanceId: String
    get() = "#$instanceOrdinal/${Integer.toHexString(System.identityHashCode(this))}"

  val lastProcessCallCount: Int
    get() = processCallCount.get()

  fun setGain(gain: Double) {
    val clamped = gain.coerceIn(0.0, MAX_GAIN)
    gainMilli.set((clamped * 1000).toInt())
  }

  override fun initialize(sampleRateHz: Int, numChannels: Int) {
    lastSampleRateHz = sampleRateHz
    lastNumChannels = numChannels
  }

  override fun reset(newRate: Int) {
    lastSampleRateHz = newRate
  }

  override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer?) {
    processCallCount.incrementAndGet()
    lastNumBands = numBands
    lastNumFrames = numFrames
    if (buffer == null) {
      return
    }
    lastBufferInfo = "capacity=${buffer.capacity()} limit=${buffer.limit()} " +
      "position=${buffer.position()} remaining=${buffer.remaining()} " +
      "assumedTotalSamples=${numBands * numFrames}"
    val base = buffer.position()
    val totalSamples = numBands * numFrames

    var peakBefore = 0
    val bandSumSquares = DoubleArray(numBands)
    var band0PeakScaled = 0L
    val gain = gainMilli.get()
    for (i in 0 until totalSamples) {
      val index = base + i * 2
      if (!PcmBuffer.hasSample(buffer, index)) {
        break
      }
      val sample = PcmBuffer.readSampleLE(buffer, index)
      val absBefore = kotlin.math.abs(sample)
      if (absBefore > peakBefore) {
        peakBefore = absBefore
      }
      val bandIndex = if (numFrames > 0) i / numFrames else 0
      if (bandIndex < numBands) {
        bandSumSquares[bandIndex] += sample.toDouble() * sample.toDouble()
      }
      if (gain != UNITY_GAIN_MILLI && bandIndex == 0) {
        val scaledAbs = kotlin.math.abs(sample.toLong() * gain / UNITY_GAIN_MILLI)
        if (scaledAbs > band0PeakScaled) {
          band0PeakScaled = scaledAbs
        }
      }
    }
    lastBandRms = IntArray(numBands) { band ->
      if (numFrames > 0) kotlin.math.sqrt(bandSumSquares[band] / numFrames).toInt() else 0
    }
    lastPeakBeforeGain = peakBefore

    if (gain == UNITY_GAIN_MILLI) {
      lastPeakAfterGain = peakBefore
      return
    }

    // A single scalar computed from band 0's own loudest sample, applied
    // only within band 0 - bands 1+ are left untouched (see class doc).
    val targetPeak = softLimitTarget(band0PeakScaled)
    val limiterScaleMilli = if (band0PeakScaled > 0) {
      ((targetPeak.toDouble() / band0PeakScaled.toDouble()) * UNITY_GAIN_MILLI).toLong()
    } else {
      UNITY_GAIN_MILLI.toLong()
    }

    var peakAfter = 0
    val band0Samples = numFrames.coerceAtMost(totalSamples)
    for (i in 0 until band0Samples) {
      val index = base + i * 2
      if (!PcmBuffer.hasSample(buffer, index)) {
        break
      }
      val sample = PcmBuffer.readSampleLE(buffer, index)
      val scaled = sample.toLong() * gain / UNITY_GAIN_MILLI
      val output = (scaled * limiterScaleMilli / UNITY_GAIN_MILLI)
        .coerceIn(-32768L, 32767L)
        .toInt()
      PcmBuffer.writeSampleLE(buffer, index, output)
      val absAfter = kotlin.math.abs(output)
      if (absAfter > peakAfter) {
        peakAfter = absAfter
      }
    }
    lastPeakAfterGain = peakAfter
  }

  // Soft-knee target: linear below the knee, smoothly compressed towards
  // full scale above it. A naive hard clamp would produce harsh digital
  // clipping distortion at high gain instead of a clean loud signal.
  private fun softLimitTarget(absSample: Long): Long {
    if (absSample <= KNEE) {
      return absSample
    }
    val over = (absSample - KNEE).toDouble()
    val headroom = (32767 - KNEE).toDouble()
    val compressed = KNEE + headroom * (1.0 - kotlin.math.exp(-over / headroom))
    return compressed.toLong().coerceIn(0L, 32767L)
  }

  companion object {
    // Total GainAudioProcessor instances ever created in this process,
    // across every LiveKitPlugin/FlutterEngine instance (e.g. the main
    // engine and the separate background gateway-service engine both load
    // this app's plugins) - a diagnostic that ruled out double-registration
    // as the cause of the earlier reported distortion.
    private val totalInstancesCreated = AtomicInteger(0)

    private const val UNITY_GAIN_MILLI = 1000
    private const val MAX_GAIN = 4.0
    private const val KNEE = 28000
  }
}
