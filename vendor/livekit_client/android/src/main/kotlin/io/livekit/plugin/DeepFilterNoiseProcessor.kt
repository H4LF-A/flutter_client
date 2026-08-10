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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Android replacement for Krisp's "Enhanced" noise suppression, which
 * requires LiveKit Cloud licensing that a self-hosted server can't satisfy
 * and silently passes audio through unprocessed instead of erroring. Ports
 * the same DeepFilterNet3 model desktop and web already use for "Enhanced",
 * via a small JNI bridge (see rust/) to the same `deep_filter` crate
 * desktop's native/webrtc-sender uses.
 *
 * Plugs into flutter_webrtc's capture-time
 * [AudioProcessingAdapter.ExternalAudioFrameProcessing] hook, the same
 * extension point [GainAudioProcessor] and Krisp both use. A device
 * diagnostic (see the mic test screen's audioProcessingFormat field)
 * confirmed WebRTC hands this hook 3 bands of 480 samples each at
 * 48kHz/mono - matching the DeepFilterNet model's required frame shape
 * exactly. Band 0 is treated as the primary signal to process; bands 1/2
 * are passed through unmodified, since their exact role in this specific
 * WebRTC build's band-split representation isn't documented anywhere
 * reachable (the WebRTC Android AAR is precompiled, no source available).
 *
 * Reads and writes band 0 via [PcmBuffer], never calling
 * `ByteBuffer.order(...)` - see that class's doc. This class used to call
 * `buffer.order(LITTLE_ENDIAN)` before `getShort`/`putShort`, the same
 * pattern every gain-processing variant used, and a remote call listener
 * confirmed hearing real distortion in the actual transmitted audio while
 * that call was in place.
 */
internal class DeepFilterNoiseProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
  private val enabled = AtomicBoolean(false)
  private val handle = AtomicLong(0)
  private val scratch = ShortArray(FRAME_SAMPLES)

  // Model load happens on whatever thread calls this (normally the platform
  // main thread, via the method channel that flips the tier setting) and can
  // take noticeably longer than a frame budget - acceptable since it's a
  // one-time cost on an explicit user setting change, not a hot path.
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

  override fun initialize(sampleRateHz: Int, numChannels: Int) {}

  override fun reset(newRate: Int) {}

  override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer?) {
    if (buffer == null || !enabled.get()) {
      return
    }
    if (numFrames != FRAME_SAMPLES) {
      // The frame shape no longer matches what this bridge was built
      // against (see class doc) - skip rather than feed the model garbage.
      return
    }
    val currentHandle = handle.get()
    if (currentHandle == 0L) {
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
