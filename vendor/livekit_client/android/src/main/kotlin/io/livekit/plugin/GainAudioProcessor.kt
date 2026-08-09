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
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger

/**
 * Applies a software gain multiplier to the locally captured microphone
 * signal. org.webrtc.AudioTrack.setVolume() has no observable effect on
 * Android for local (captured) tracks - only for remote/playout tracks - so
 * input-volume control has to happen here instead, in flutter_webrtc's
 * capture-time [AudioProcessingAdapter.ExternalAudioFrameProcessing] hook
 * (the same extension point the Krisp noise filter uses), mutating the raw
 * PCM buffer in place before it's encoded and sent.
 *
 * Also records the sample rate/channel/band-framing values WebRTC actually
 * hands to this hook, plus the observed peak amplitude before/after gain is
 * applied - diagnostics to prove (rather than assume) the gain is actually
 * landing on the buffer that gets encoded and sent.
 */
internal class GainAudioProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
  // Fixed-point (x1000) so the audio-processing thread can read this
  // lock-free without contending with the Dart-triggered setter.
  private val gainMilli = AtomicInteger(UNITY_GAIN_MILLI)

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
    lastNumBands = numBands
    lastNumFrames = numFrames
    if (buffer == null) {
      return
    }
    val gain = gainMilli.get()
    val originalOrder = buffer.order()
    buffer.order(ByteOrder.LITTLE_ENDIAN)
    val base = buffer.position()
    val totalSamples = numBands * numFrames
    var peakBefore = 0
    var peakAfter = 0
    for (i in 0 until totalSamples) {
      val index = base + i * 2
      if (index + 2 > buffer.limit()) {
        break
      }
      val sample = buffer.getShort(index).toInt()
      val absBefore = kotlin.math.abs(sample)
      if (absBefore > peakBefore) {
        peakBefore = absBefore
      }
      if (gain == UNITY_GAIN_MILLI) {
        if (absBefore > peakAfter) {
          peakAfter = absBefore
        }
        continue
      }
      val scaledRaw = (sample.toLong() * gain / UNITY_GAIN_MILLI).toInt()
      // Soft-knee limiter: linear below the knee, smoothly compressed
      // towards full scale above it. A naive hard clamp here would produce
      // harsh digital clipping distortion at high gain instead of a clean
      // loud signal.
      val limited = softLimit(scaledRaw)
      buffer.putShort(index, limited.toShort())
      val absAfter = kotlin.math.abs(limited)
      if (absAfter > peakAfter) {
        peakAfter = absAfter
      }
    }
    buffer.order(originalOrder)
    lastPeakBeforeGain = peakBefore
    lastPeakAfterGain = peakAfter
  }

  private fun softLimit(sample: Int): Int {
    val absSample = kotlin.math.abs(sample)
    if (absSample <= KNEE) {
      return sample
    }
    val sign = if (sample < 0) -1 else 1
    val over = (absSample - KNEE).toDouble()
    val headroom = (32767 - KNEE).toDouble()
    val compressed = KNEE + headroom * (1.0 - kotlin.math.exp(-over / headroom))
    return (sign * compressed).toInt().coerceIn(-32768, 32767)
  }

  companion object {
    private const val UNITY_GAIN_MILLI = 1000
    private const val MAX_GAIN = 4.0
    private const val KNEE = 28000
  }
}
