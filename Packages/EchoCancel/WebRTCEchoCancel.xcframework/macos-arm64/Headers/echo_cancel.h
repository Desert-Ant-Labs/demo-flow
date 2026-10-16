// A small C face for WebRTC's echo canceller (AEC3), so Swift can use it
// without C++. Mono float audio in 10 ms frames, samples in -1...1.
#ifndef ECHO_CANCEL_H
#define ECHO_CANCEL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EchoCancel EchoCancel;

/// A canceller for audio at `sample_rate` (16000, 32000 or 48000), or NULL.
EchoCancel *echo_cancel_create(int sample_rate);
void echo_cancel_destroy(EchoCancel *canceller);

/// The samples in one frame: a hundredth of the sample rate.
int echo_cancel_frame(const EchoCancel *canceller);

/// One frame of what the speakers play, the echo to look for. 0 on success.
int echo_cancel_render(EchoCancel *canceller, const float *frame);

/// One frame of the microphone, with the echo taken out in place. 0 on success.
int echo_cancel_capture(EchoCancel *canceller, float *frame);

#ifdef __cplusplus
}
#endif

#endif
