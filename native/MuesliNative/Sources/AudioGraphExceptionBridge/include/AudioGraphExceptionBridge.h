#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable result of reading AVAudioEngine's input node while protected by
/// the Objective-C exception boundary. `error` is non-nil when AVFAudio raised
/// or the input audio unit could not report a current device.
@interface MuesliAudioInputState : NSObject
@property(nonatomic, readonly, nullable) AVAudioFormat *inputFormat;
@property(nonatomic, readonly, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readonly) AudioStreamBasicDescription inputDescription;
@property(nonatomic, readonly) AudioStreamBasicDescription outputDescription;
@property(nonatomic, readonly) AudioObjectID currentDeviceID;
@property(nonatomic, readonly) BOOL hasCurrentDevice;
@property(nonatomic, readonly, nullable) NSError *error;
@end

FOUNDATION_EXPORT MuesliAudioInputState *MuesliAudioGraphReadInputState(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphSetInputDevice(
    AVAudioEngine *engine,
    AudioObjectID deviceID
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock block
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphRemoveInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus
);

/// AVFAudio graph mutations can raise Objective-C exceptions for transient
/// CoreAudio format races. Swift's `do`/`catch` cannot intercept them, so each
/// mutation must enter Objective-C directly inside this boundary.
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphInstallTap(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    AVAudioNodeTapBlock block
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphPrepareEngine(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStartEngine(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphRemoveTap(
    AVAudioNode *node,
    AVAudioNodeBus bus
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStopEngine(
    AVAudioEngine *engine
);

NS_ASSUME_NONNULL_END
