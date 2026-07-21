#import "AudioGraphExceptionBridge.h"

static NSString *const MuesliAudioGraphErrorDomain = @"MuesliAudioGraph";

static NSError *MuesliAudioGraphExceptionError(NSException *exception, NSString *operation) {
    return [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"%@ failed: %@", operation,
                                           exception.reason ?: exception.name]}];
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

NSError *MuesliAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus) {
    @try {
        [engine.inputNode removeTapOnBus:bus];
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
