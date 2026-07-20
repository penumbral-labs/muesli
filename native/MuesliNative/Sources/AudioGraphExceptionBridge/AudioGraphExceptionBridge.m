#import "AudioGraphExceptionBridge.h"

static NSString *const MuesliAudioGraphErrorDomain = @"MuesliAudioGraph";

static NSError *MuesliAudioGraphExceptionError(NSException *exception, NSString *operation) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ failed: %@", operation, exception.reason ?: exception.name],
        @"operation": operation,
        @"exceptionName": exception.name,
    }];
    if (exception.reason != nil) {
        userInfo[@"exceptionReason"] = exception.reason;
    }
    return [NSError errorWithDomain:MuesliAudioGraphErrorDomain code:1 userInfo:userInfo];
}

@interface MuesliAudioInputState ()
@property(nonatomic, readwrite, nullable) AVAudioFormat *inputFormat;
@property(nonatomic, readwrite, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readwrite) AudioStreamBasicDescription inputDescription;
@property(nonatomic, readwrite) AudioStreamBasicDescription outputDescription;
@property(nonatomic, readwrite) AudioObjectID currentDeviceID;
@property(nonatomic, readwrite) BOOL hasCurrentDevice;
@property(nonatomic, readwrite, nullable) NSError *error;
@end

@implementation MuesliAudioInputState
@end

static MuesliAudioInputState *MuesliAudioInputErrorState(NSError *error) {
    MuesliAudioInputState *state = [[MuesliAudioInputState alloc] init];
    state.error = error;
    return state;
}

MuesliAudioInputState *MuesliAudioGraphReadInputState(AVAudioEngine *engine) {
    @try {
        AVAudioInputNode *node = engine.inputNode;
        AVAudioFormat *inputFormat = [node inputFormatForBus:0];
        AVAudioFormat *outputFormat = [node outputFormatForBus:0];
        const AudioStreamBasicDescription *inputDescription = inputFormat.streamDescription;
        const AudioStreamBasicDescription *outputDescription = outputFormat.streamDescription;
        if (inputDescription == NULL || outputDescription == NULL) {
            return MuesliAudioInputErrorState(
                [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                                    code:3
                                userInfo:@{NSLocalizedDescriptionKey: @"The microphone input format is unavailable"}]
            );
        }

        MuesliAudioInputState *state = [[MuesliAudioInputState alloc] init];
        state.inputFormat = inputFormat;
        state.outputFormat = outputFormat;
        state.inputDescription = *inputDescription;
        state.outputDescription = *outputDescription;

        AudioUnit audioUnit = node.audioUnit;
        if (audioUnit != NULL) {
            AudioObjectID deviceID = kAudioObjectUnknown;
            UInt32 dataSize = sizeof(deviceID);
            OSStatus status = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                &dataSize
            );
            if (status == noErr && deviceID != kAudioObjectUnknown) {
                state.currentDeviceID = deviceID;
                state.hasCurrentDevice = YES;
            }
        }
        return state;
    } @catch (NSException *exception) {
        return MuesliAudioInputErrorState(
            MuesliAudioGraphExceptionError(exception, @"Read microphone input state")
        );
    }
}

NSError *MuesliAudioGraphSetInputDevice(AVAudioEngine *engine, AudioObjectID deviceID) {
    @try {
        AudioUnit audioUnit = engine.inputNode.audioUnit;
        if (audioUnit == NULL) {
            return [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                                       code:4
                                   userInfo:@{NSLocalizedDescriptionKey: @"No audio unit is available for preferred input routing"}];
        }
        OSStatus status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            sizeof(deviceID)
        );
        if (status != noErr) {
            return [NSError errorWithDomain:NSOSStatusErrorDomain
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not select microphone device %u", deviceID]}];
        }
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Select microphone input device");
    }
}

NSError *MuesliAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock block
) {
    @try {
        [engine.inputNode installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Install microphone tap");
    }
}

NSError *MuesliAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus) {
    @try {
        [engine.inputNode removeTapOnBus:bus];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Remove microphone tap");
    }
}

NSError *MuesliAudioGraphInstallTap(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock block
) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Install microphone tap");
    }
}

NSError *MuesliAudioGraphPrepareEngine(AVAudioEngine *engine) {
    @try {
        [engine prepare];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Prepare audio engine");
    }
}

NSError *MuesliAudioGraphStartEngine(AVAudioEngine *engine) {
    @try {
        NSError *error = nil;
        if (![engine startAndReturnError:&error]) {
            return error ?: [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Start audio engine failed"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Start audio engine");
    }
}

NSError *MuesliAudioGraphRemoveTap(AVAudioNode *node, AVAudioNodeBus bus) {
    @try {
        [node removeTapOnBus:bus];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Remove microphone tap");
    }
}

NSError *MuesliAudioGraphStopEngine(AVAudioEngine *engine) {
    @try {
        [engine stop];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Stop audio engine");
    }
}
