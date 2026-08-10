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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Android replacement for Krisp's "Enhanced" noise suppression, which
 * requires LiveKit Cloud licensing that a self-hosted server can't satisfy
 * and silently passes audio through unprocessed instead of erroring. Ports
 * the same DeepFilterNet3 model desktop and web already use for "Enhanced",
 * via a small JNI bridge (see rust/) to the same `deep_filter` crate
 * desktop's native/webrtc-sender uses.
 *
 * Plugs into [RawAudioBufferProcessor] - raw, pre-APM PCM straight from
 * AudioRecord.read(), fullband mono at the true capture rate - rather than
 * WebRTC's internal capture-post-processing hook (see [GainAudioProcessor]'s
 * doc for why: undocumented band-split semantics that produced real,
 * remote-confirmed distortion no matter how carefully it was read/written).
 * The model needs exactly [FRAME_SAMPLES] (480, 10ms @ 48kHz) samples per
 * call. This hook's own delivery chunk size is expected (matching the
 * standard WebRTC 10ms convention) to already be exactly that; [scratch]
 * is a fixed-size reusable buffer rather than an accumulator spanning
 * multiple calls, because a partial frame carried over to the *next*
 * callback couldn't be written back into *this* callback's buffer (which
 * is gone by then) - so a chunk size that doesn't match is skipped and
 * recorded via [lastChunkSamples] rather than silently misprocessed.
 */
internal class DeepFilterNoiseProcessor : RawAudioBufferProcessor.RawPcmProcessor {
  private val enabled = AtomicBoolean(false)
  private val handle = AtomicLong(0)
  private val scratch = ShortArray(FRAME_SAMPLES)

  @Volatile
  var lastChunkSamples: Int = 0
    private set

  fun setEnabled(value: Boolean) {
    enabled.set(value)
    if (value) {
      ensureInitialized()
    }
  }

  private fun ensureInitialized() {
    if (handle.get() != 0L) {
      return
    }
    synchronized(this) {
      if (handle.get() == 0L) {
        handle.set(nativeInit())
      }
    }
  }

  override fun process(buffer: ByteBuffer, audioFormat: Int, channelCount: Int, sampleRate: Int, bytesRead: Int) {
    if (!enabled.get() || audioFormat != AudioFormat.ENCODING_PCM_16BIT) {
      return
    }
    val currentHandle = handle.get()
    if (currentHandle == 0L) {
      return
    }
    val totalSamples = bytesRead / 2
    lastChunkSamples = totalSamples
    if (totalSamples != FRAME_SAMPLES) {
      return
    }
    val base = buffer.position()
    if (!PcmBuffer.hasSample(buffer, base + (FRAME_SAMPLES - 1) * 2)) {
      return
    }
    for (i in 0 until FRAME_SAMPLES) {
      scratch[i] = PcmBuffer.readSampleLE(buffer, base + i * 2).toShort()
    }
    nativeProcess(currentHandle, scratch)
    for (i in 0 until FRAME_SAMPLES) {
      PcmBuffer.writeSampleLE(buffer, base + i * 2, scratch[i].toInt())
    }
  }

  fun destroy() {
    val currentHandle = handle.getAndSet(0)
    if (currentHandle != 0L) {
      nativeDestroy(currentHandle)
    }
  }

  private external fun nativeInit(): Long
  private external fun nativeProcess(handle: Long, samples: ShortArray)
  private external fun nativeDestroy(handle: Long)

  companion object {
    private const val FRAME_SAMPLES = 480

    init {
      System.loadLibrary("deep_filter_android_native")
    }
  }
}
