package com.cloudwebrtc.webrtc.audio;

import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Fans out WebRTC's {@link JavaAudioDeviceModule.AudioBufferCallback} - raw,
 * pre-APM PCM straight from {@code AudioRecord.read()}, before any band
 * splitting, AEC/NS/AGC, or other WebRTC internal processing - to any number
 * of registered {@link RawPcmProcessor}s.
 *
 * This is a deliberately different, simpler extension point than
 * {@link AudioProcessingAdapter} (WebRTC's internal
 * capture-post-processing hook, which operates on a frequency band-split
 * representation whose exact semantics aren't documented for this
 * precompiled AAR). AudioBufferCallback instead hands over fullband mono
 * PCM at the true capture sample rate, with an explicit bytesRead count -
 * matching how this app's web and desktop clients process audio *before*
 * handing it to their respective transport layers, rather than hooking into
 * transport-internal pipeline state.
 */
public class RawAudioBufferProcessor implements JavaAudioDeviceModule.AudioBufferCallback {
  public interface RawPcmProcessor {
    /**
     * Called with raw captured PCM. May mutate {@code buffer} in place
     * (from {@code buffer.position()} for {@code bytesRead} bytes) - the
     * mutated contents are what gets encoded and sent.
     */
    void process(ByteBuffer buffer, int audioFormat, int channelCount, int sampleRate, int bytesRead);
  }

  private final List<RawPcmProcessor> processors = new ArrayList<>();

  public void addProcessor(RawPcmProcessor processor) {
    synchronized (processors) {
      processors.add(processor);
    }
  }

  public void removeProcessor(RawPcmProcessor processor) {
    synchronized (processors) {
      processors.remove(processor);
    }
  }

  @Override
  public long onBuffer(ByteBuffer buffer, int audioFormat, int channelCount, int sampleRate, int bytesRead, long captureTimeNs) {
    synchronized (processors) {
      for (RawPcmProcessor processor : processors) {
        processor.process(buffer, audioFormat, channelCount, sampleRate, bytesRead);
      }
    }
    return captureTimeNs;
  }
}
