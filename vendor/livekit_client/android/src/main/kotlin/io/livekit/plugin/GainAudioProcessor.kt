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
 * DISABLED (diagnostic-only, no longer mutates audio): every variant tried
 * here - a per-band limiter, a cross-band-uniform limiter, and finally
 * restricting writes to band 0 only - produced the same "ear-raping"
 * distortion at any non-unity gain, while leaving the buffer completely
 * untouched (gain == unity) was confirmed clean every time. That rules out
 * every hypothesis about *which* samples get written or *how* they're
 * scaled; the only surviving correlation is "this class writes to the
 * buffer at all". Rather than keep guessing at further write strategies,
 * this now only reads (for the diagnostics below) and never calls
 * buffer.putShort() - input-volume control falls back to
 * org.webrtc.AudioTrack.setVolume() (Helper.setVolume on the Dart side),
 * WebRTC's own SDK API, which couldn't be cleanly evaluated before now
 * since this class's writes were always layered on top of it. Earlier
 * testing had found AudioTrack.setVolume() to be a no-op for local tracks,
 * but that conclusion predates several other fixes this session
 * (MODE_IN_COMMUNICATION, forced-on hardware noise suppression, the
 * VOICE_COMMUNICATION audio source) that could have been masking it.
 *
 * Still records the sample rate/channel/band-framing values and observed
 * peak/RMS WebRTC hands this hook, and the gain value the Dart side last
 * requested (never applied) - diagnostics kept from the investigation that
 * got this class to this point.
 */
internal class GainAudioProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
  // Fixed-point (x1000). No longer read by process() (see class doc) -
  // kept only so the last value Dart requested is visible as a diagnostic.
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

  // TEMPORARY diagnostic: per-band RMS of the raw (pre-gain) signal, to
  // characterize what each band actually carries. Remove once the
  // noise-suppression artifact investigation is done.
  @Volatile
  var lastBandRms: IntArray = IntArray(0)
    private set

  // TEMPORARY diagnostic: the buffer's actual capacity/limit/position/
  // remaining, captured before any read/write. numBands*numFrames has been
  // assumed to be the total sample count in this buffer - if that's wrong
  // (e.g. numFrames is actually the *total* frame length and each band is
  // numFrames/numBands samples, not numFrames samples), every read/write
  // this class does would be misaligned relative to true band boundaries,
  // silently bounded by the existing index+2>limit() guard rather than
  // crashing. This settles it empirically instead of by assumption.
  @Volatile
  var lastBufferInfo: String = ""
    private set

  // TEMPORARY diagnostic: how many times THIS instance's process() has been
  // invoked, plus an object identity string. If more than one
  // GainAudioProcessor instance is simultaneously registered into the
  // shared, process-wide AudioProcessingController (see LiveKitPlugin's
  // ensureGainProcessorRegistered doc), gain would be applied more than
  // once per frame - compounding rather than simply applying once. This
  // makes that directly checkable instead of assumed.
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
    val originalOrder = buffer.order()
    buffer.order(ByteOrder.LITTLE_ENDIAN)
    val base = buffer.position()
    val totalSamples = numBands * numFrames

    // Read-only: peak/RMS of the actual captured signal, across every band.
    // Nothing below writes to the buffer - see class doc.
    var peakBefore = 0
    val bandSumSquares = DoubleArray(numBands)
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
      val bandIndex = if (numFrames > 0) i / numFrames else 0
      if (bandIndex < numBands) {
        bandSumSquares[bandIndex] += sample.toDouble() * sample.toDouble()
      }
    }
    lastBandRms = IntArray(numBands) { band ->
      if (numFrames > 0) kotlin.math.sqrt(bandSumSquares[band] / numFrames).toInt() else 0
    }
    lastPeakBeforeGain = peakBefore
    lastPeakAfterGain = peakBefore
    buffer.order(originalOrder)
  }

  companion object {
    // TEMPORARY diagnostic: total GainAudioProcessor instances ever created
    // in this process, across every LiveKitPlugin/FlutterEngine instance
    // (e.g. the main engine and the separate background gateway-service
    // engine both load this app's plugins). More than one instance existing
    // doesn't by itself prove double-processing (a second instance's own
    // gain stays at unity/no-op unless something also calls setGain on it),
    // but it's the first fact needed to rule the theory in or out.
    private val totalInstancesCreated = AtomicInteger(0)

    private const val UNITY_GAIN_MILLI = 1000
    private const val MAX_GAIN = 4.0
  }
}
