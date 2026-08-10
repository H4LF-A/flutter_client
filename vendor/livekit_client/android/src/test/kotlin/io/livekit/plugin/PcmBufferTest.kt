package io.livekit.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PcmBufferTest {

  @Test
  fun `reads a little-endian sample without needing buffer order set`() {
    // Deliberately leave the buffer at its default order (BIG_ENDIAN per
    // the JLS) to prove readSampleLE doesn't depend on it.
    val buffer = ByteBuffer.allocateDirect(4)
    buffer.put(0, 0x34)
    buffer.put(1, 0x12)
    assertEquals(0x1234, PcmBuffer.readSampleLE(buffer, 0))
  }

  @Test
  fun `reads a negative sample correctly (sign extension)`() {
    val buffer = ByteBuffer.allocateDirect(2)
    // -1 as little-endian 16-bit: 0xFF 0xFF.
    buffer.put(0, 0xFF.toByte())
    buffer.put(1, 0xFF.toByte())
    assertEquals(-1, PcmBuffer.readSampleLE(buffer, 0))

    // Short.MIN_VALUE (-32768) as little-endian: 0x00 0x80.
    buffer.put(0, 0x00)
    buffer.put(1, 0x80.toByte())
    assertEquals(-32768, PcmBuffer.readSampleLE(buffer, 0))
  }

  @Test
  fun `write then read round-trips across the full 16-bit range`() {
    val buffer = ByteBuffer.allocateDirect(2)
    for (value in listOf(0, 1, -1, 32767, -32768, 12345, -12345)) {
      PcmBuffer.writeSampleLE(buffer, 0, value)
      assertEquals(value, PcmBuffer.readSampleLE(buffer, 0), "round-trip failed for $value")
    }
  }

  @Test
  fun `write does not depend on and does not need to touch buffer order`() {
    val buffer = ByteBuffer.allocateDirect(2)
    val orderBefore = buffer.order()
    PcmBuffer.writeSampleLE(buffer, 0, 0x1234)
    assertEquals(orderBefore, buffer.order(), "writeSampleLE must not mutate buffer.order()")
    // Confirm the actual bytes are little-endian regardless of the
    // buffer's (untouched) order property.
    assertEquals(0x34.toByte(), buffer.get(0))
    assertEquals(0x12.toByte(), buffer.get(1))
  }

  @Test
  fun `matches ByteBuffer's own little-endian getShort putShort for reference`() {
    val buffer = ByteBuffer.allocateDirect(2).order(ByteOrder.LITTLE_ENDIAN)
    for (value in listOf(0, 1, -1, 32767, -32768, 500, -500)) {
      buffer.putShort(0, value.toShort())
      assertEquals(
        buffer.getShort(0).toInt(),
        PcmBuffer.readSampleLE(buffer, 0),
        "PcmBuffer must agree with ByteBuffer's own little-endian accessors for $value",
      )
    }
  }

  @Test
  fun `hasSample bounds-checks correctly at the buffer edge`() {
    val buffer = ByteBuffer.allocateDirect(4)
    assertTrue(PcmBuffer.hasSample(buffer, 0))
    assertTrue(PcmBuffer.hasSample(buffer, 2))
    assertFalse(PcmBuffer.hasSample(buffer, 3), "only 1 byte remains at index 3")
    assertFalse(PcmBuffer.hasSample(buffer, 4), "index 4 is out of bounds")
    assertFalse(PcmBuffer.hasSample(buffer, -1))
  }
}
