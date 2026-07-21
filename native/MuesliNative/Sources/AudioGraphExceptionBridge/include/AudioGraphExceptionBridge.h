#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    AVAudioNodeTapBlock block
);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphPrepareEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStartEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStopEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
