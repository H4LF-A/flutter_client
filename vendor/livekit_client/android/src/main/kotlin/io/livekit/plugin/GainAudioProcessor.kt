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
 * WebRTC hands this hook a frequency band-split representation, not
 * independent/duplicate channels - confirmed via the per-band RMS
 * diagnostic below, which shows materially different, frequency-dependent
 * energy per band. A synthesis filter downstream (inside the precompiled
 * WebRTC AAR, no source available) recombines these bands into the final
 * fullband signal, and that recombination only stays correct if the
 * *relative* amplitude between bands is preserved. Because of that, gain
 * and limiting here are applied as a single linear scalar for the whole
 * frame - computed once from the loudest sample across every band - rather
 * than per-band or per-sample, which would compress bands by different
 * amounts and corrupt the reconstruction even though each band's own
 * numbers would look reasonable in isolation.
 *
 * Also records the sample rate/channel/band-framing values WebRTC actually
 * hands to this hook, plus observed peak amplitude before/after gain -
 * diagnostics to prove (rather than assume) the gain is actually landing on
 * the buffer that gets encoded and sent.
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
    val gain = gainMilli.get()
    val originalOrder = buffer.order()
    buffer.order(ByteOrder.LITTLE_ENDIAN)
    val base = buffer.position()
    val totalSamples = numBands * numFrames

    // Pass 1: measure the raw signal (peak, per-band RMS) across every band
    // - diagnostic only, does not affect what gets modified below - and, if
    // gain is non-unity, the peak the gain multiply alone would produce
    // within BAND 0 ONLY (see EXPERIMENT note below).
    var peakBefore = 0
    val bandSumSquares = DoubleArray(numBands)
    var globalPeakScaled = 0L
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
      // EXPERIMENT: only band 0 (i < numFrames) is a candidate for gain -
      // matching the scope DeepFilterNoiseProcessor already safely uses.
      // Reported audio distortion has survived every other explanation
      // tried (feedback, AGC, duplicate processing, audio source) and
      // correlates only with "does this code modify the buffer at all" -
      // this isolates whether modifying band 1 specifically (as the
      // previous cross-band-uniform version did) is the actual cause,
      // since band 1 might not be simple duplicate/parallel audio content.
      if (gain != UNITY_GAIN_MILLI && i < numFrames) {
        val scaledAbs = kotlin.math.abs(sample.toLong() * gain / UNITY_GAIN_MILLI)
        if (scaledAbs > globalPeakScaled) {
          globalPeakScaled = scaledAbs
        }
      }
    }
    lastBandRms = IntArray(numBands) { band ->
      if (numFrames > 0) kotlin.math.sqrt(bandSumSquares[band] / numFrames).toInt() else 0
    }
    lastPeakBeforeGain = peakBefore

    if (gain == UNITY_GAIN_MILLI) {
      buffer.order(originalOrder)
      lastPeakAfterGain = peakBefore
      return
    }

    // A single scalar computed from band 0's own loudest sample, applied
    // only within band 0 (see EXPERIMENT note above) - bands 1+ are left
    // completely untouched this build.
    val targetPeak = softLimitTarget(globalPeakScaled)
    val limiterScaleMilli = if (globalPeakScaled > 0) {
      ((targetPeak.toDouble() / globalPeakScaled.toDouble()) * UNITY_GAIN_MILLI).toLong()
    } else {
      UNITY_GAIN_MILLI.toLong()
    }

    var peakAfter = 0
    val band0Samples = numFrames.coerceAtMost(totalSamples)
    for (i in 0 until band0Samples) {
      val index = base + i * 2
      if (index + 2 > buffer.limit()) {
        break
      }
      val sample = buffer.getShort(index).toInt()
      val scaled = sample.toLong() * gain / UNITY_GAIN_MILLI
      val output = (scaled * limiterScaleMilli / UNITY_GAIN_MILLI)
        .coerceIn(-32768L, 32767L)
        .toInt()
      buffer.putShort(index, output.toShort())
      val absAfter = kotlin.math.abs(output)
      if (absAfter > peakAfter) {
        peakAfter = absAfter
      }
    }
    buffer.order(originalOrder)
    lastPeakAfterGain = peakAfter
  }

  // Soft-knee target: linear below the knee, smoothly compressed towards
  // full scale above it. Operates on the frame's single global peak (see
  // class doc), not per-sample or per-band - a naive hard clamp per sample
  // would produce harsh digital clipping distortion, and limiting per-band
  // independently would corrupt the cross-band relationship WebRTC's
  // synthesis filter depends on.
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
    private const val KNEE = 28000
  }
}
