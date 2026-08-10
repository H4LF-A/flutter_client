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

import android.media.AudioFormat
import com.cloudwebrtc.webrtc.audio.RawAudioBufferProcessor
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

/**
 * Applies a software gain multiplier to the locally captured microphone
 * signal. org.webrtc.AudioTrack.setVolume() has no observable effect on
 * Android for local (captured) tracks, so input-volume control happens
 * here instead.
 *
 * Plugs into [RawAudioBufferProcessor] - raw, pre-APM PCM straight from
 * AudioRecord.read(), fullband mono at the true capture rate, with an
 * explicit bytesRead count - rather than WebRTC's internal capture-post-
 * processing hook (a frequency band-split representation whose exact
 * semantics turned out not to be documented anywhere reachable for this
 * precompiled AAR, and which - across every strategy tried for reading and
 * writing it - produced real distortion confirmed by a remote call
 * participant on the actual transmitted audio). This hook receives one
 * genuine, coherent audio stream, so gain applies uniformly across the
 * whole buffer - no band concept to reason about.
 *
 * Reads and writes samples via [PcmBuffer] (single-byte absolute access,
 * never touching `ByteBuffer.order()`).
 */
internal class GainAudioProcessor : RawAudioBufferProcessor.RawPcmProcessor {
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
  var lastBytesRead: Int? = null
    private set

  @Volatile
  var lastPeakBeforeGain: Int = 0
    private set

  @Volatile
  var lastPeakAfterGain: Int = 0
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

  override fun process(buffer: ByteBuffer, audioFormat: Int, channelCount: Int, sampleRate: Int, bytesRead: Int) {
    processCallCount.incrementAndGet()
    lastSampleRateHz = sampleRate
    lastNumChannels = channelCount
    lastBytesRead = bytesRead
    lastBufferInfo = "audioFormat=$audioFormat capacity=${buffer.capacity()} " +
      "position=${buffer.position()} limit=${buffer.limit()}"
    if (audioFormat != AudioFormat.ENCODING_PCM_16BIT) {
      // Unsupported format - skip rather than misinterpret bytes.
      return
    }
    val base = buffer.position()
    val totalSamples = bytesRead / 2
    val gain = gainMilli.get()

    var peakBefore = 0
    var peakScaled = 0L
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
      if (gain != UNITY_GAIN_MILLI) {
        val scaledAbs = kotlin.math.abs(sample.toLong() * gain / UNITY_GAIN_MILLI)
        if (scaledAbs > peakScaled) {
          peakScaled = scaledAbs
        }
      }
    }
    lastPeakBeforeGain = peakBefore

    if (gain == UNITY_GAIN_MILLI) {
      lastPeakAfterGain = peakBefore
      return
    }

    // A single scalar for the whole buffer: linear gain, then (if needed) a
    // uniform additional scale-down so the loudest sample lands within the
    // soft-limited target.
    val targetPeak = softLimitTarget(peakScaled)
    val limiterScaleMilli = if (peakScaled > 0) {
      ((targetPeak.toDouble() / peakScaled.toDouble()) * UNITY_GAIN_MILLI).toLong()
    } else {
      UNITY_GAIN_MILLI.toLong()
    }

    var peakAfter = 0
    for (i in 0 until totalSamples) {
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
    // Total GainAudioProcessor instances ever created in this process -
    // ruled out double-registration as a cause of the earlier reported
    // distortion (confirmed exactly one instance was ever active).
    private val totalInstancesCreated = AtomicInteger(0)

    private const val UNITY_GAIN_MILLI = 1000
    private const val MAX_GAIN = 4.0
    private const val KNEE = 28000
  }
}
