#include "echo_cancel.h"

#include <vector>

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

struct EchoCancel {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  // Where the far end goes after it is listened to; it is not used.
  std::vector<float> played;
};

extern "C" EchoCancel *echo_cancel_create(int sample_rate) {
  if (sample_rate != 16000 && sample_rate != 32000 && sample_rate != 48000) return nullptr;
  webrtc::AudioProcessing::Config config;
  // Only the echo canceller, with the high-pass filter it expects in front.
  // No noise suppression or gain control: the transcriber hears the voice as
  // the microphone took it.
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  config.high_pass_filter.enabled = true;
  rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
  if (!apm) return nullptr;
  apm->ApplyConfig(config);
  webrtc::StreamConfig stream(sample_rate, 1);
  return new EchoCancel{apm, stream, std::vector<float>(stream.num_frames())};
}

extern "C" void echo_cancel_destroy(EchoCancel *canceller) { delete canceller; }

extern "C" int echo_cancel_frame(const EchoCancel *canceller) { return (int)canceller->stream.num_frames(); }

extern "C" int echo_cancel_render(EchoCancel *canceller, const float *frame) {
  const float *src[1] = {frame};
  float *dest[1] = {canceller->played.data()};
  return canceller->apm->ProcessReverseStream(src, canceller->stream, canceller->stream, dest);
}

extern "C" int echo_cancel_capture(EchoCancel *canceller, float *frame) {
  // Both streams come from one capture on one clock, so the delay between
  // them is only the room's; AEC3 finds it on its own.
  canceller->apm->set_stream_delay_ms(0);
  const float *src[1] = {frame};
  float *dest[1] = {frame};
  return canceller->apm->ProcessStream(src, canceller->stream, canceller->stream, dest);
}
