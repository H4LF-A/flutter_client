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

import java.nio.ByteBuffer

/**
 * Reads/writes 16-bit little-endian PCM samples in the ByteBuffer WebRTC
 * hands to [com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter.ExternalAudioFrameProcessing.process],
 * using only single-byte absolute get/put - deliberately never calls
 * `ByteBuffer.order(...)`.
 *
 * `ByteBuffer.order()` is a mutable, stateful property of the buffer OBJECT
 * itself, not a copy of the data - and it only affects Java-side multi-byte
 * accessors (getShort/putShort); native code reading the same underlying
 * memory via a raw pointer (the standard, fast JNI pattern for a hot audio
 * path) never looks at it. Every earlier version of this app's own
 * audio-processing code that called `buffer.order(LITTLE_ENDIAN)` before
 * `getShort`/`putShort` - across several different gain-limiting strategies
 * - produced real distortion confirmed by a remote call participant on the
 * actual transmitted audio; removing that call (falling back to a
 * read-only, never-mutating-order diagnostic) did not reproduce it. Krisp's
 * own working noise-filter implementation
 * (`LiveKitKrispNoiseFilter.process`) never touches `buffer.order()` either
 * - it hands the buffer straight to native code. A single byte has no
 * endianness, so absolute single-byte get/put is safe regardless of
 * whatever order the buffer's creator set or expects, and never mutates
 * shared state that other code touching the same buffer object might rely
 * on.
 */
internal object PcmBuffer {
  /** True if a full 2-byte sample can be read/written starting at [index]. */
  fun hasSample(buffer: ByteBuffer, index: Int): Boolean = index >= 0 && index + 2 <= buffer.limit()

  /** Reads one little-endian, sign-extended 16-bit sample at [index]. */
  fun readSampleLE(buffer: ByteBuffer, index: Int): Int {
    val lo = buffer.get(index).toInt() and 0xFF
    val hi = buffer.get(index + 1).toInt() // Byte -> Int sign-extends the high byte correctly.
    return (hi shl 8) or lo
  }

  /** Writes [value] (truncated to 16 bits) as a little-endian sample at [index]. */
  fun writeSampleLE(buffer: ByteBuffer, index: Int, value: Int) {
    buffer.put(index, (value and 0xFF).toByte())
    buffer.put(index + 1, ((value shr 8) and 0xFF).toByte())
  }
}
