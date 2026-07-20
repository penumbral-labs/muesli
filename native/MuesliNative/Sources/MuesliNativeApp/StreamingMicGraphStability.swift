import AVFoundation
import CoreAudio
import Foundation

/// Value copy of an ASBD. Keeping this separate from AVAudioFormat makes route
/// settlement deterministic and straightforward to regression-test.
struct StreamingMicAudioFormatFingerprint: Equatable, Sendable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(_ format: AVAudioFormat) {
        self.init(format.streamDescription.pointee)
    }

    init(_ description: AudioStreamBasicDescription) {
        sampleRate = description.mSampleRate
        formatID = description.mFormatID
        formatFlags = description.mFormatFlags
        bytesPerPacket = description.mBytesPerPacket
        framesPerPacket = description.mFramesPerPacket
        bytesPerFrame = description.mBytesPerFrame
        channelsPerFrame = description.mChannelsPerFrame
        bitsPerChannel = description.mBitsPerChannel
    }

    init(
        sampleRate: Double,
        formatID: AudioFormatID = kAudioFormatLinearPCM,
        formatFlags: AudioFormatFlags = 0,
        bytesPerPacket: UInt32 = 4,
        framesPerPacket: UInt32 = 1,
        bytesPerFrame: UInt32 = 4,
        channelsPerFrame: UInt32 = 1,
        bitsPerChannel: UInt32 = 32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
    }

    var isUsable: Bool {
        sampleRate.isFinite && sampleRate > 0 && channelsPerFrame > 0
    }
}

struct StreamingMicRouteFingerprint: Equatable, Sendable {
    let requestedDeviceID: AudioObjectID?
    let defaultInputDeviceID: AudioObjectID?
    let actualDeviceID: AudioObjectID?
    let actualDeviceIsAvailable: Bool
    let actualDeviceIsSystemDefaultAggregate: Bool
    let actualNominalSampleRate: Double?
    let inputFormat: StreamingMicAudioFormatFingerprint
    let outputFormat: StreamingMicAudioFormatFingerprint

    var validationFailure: String? {
        guard actualDeviceID != nil else {
            return "The audio engine has no current input device"
        }
        guard actualDeviceIsAvailable else {
            return "The audio engine input device is no longer available"
        }
        if let requestedDeviceID {
            guard actualDeviceID == requestedDeviceID else {
                return "The audio engine has not switched to the selected microphone"
            }
        } else {
            guard defaultInputDeviceID != nil else {
                return "The system default microphone is not available"
            }
            guard actualDeviceID == defaultInputDeviceID
                    || actualDeviceIsSystemDefaultAggregate else {
                return "The audio engine has not switched to the system default microphone"
            }
        }
        guard inputFormat.isUsable, outputFormat.isUsable else {
            return "The microphone route does not yet expose a usable input format"
        }
        guard inputFormat == outputFormat else {
            return "The microphone hardware and tap formats have not settled"
        }
        if let actualNominalSampleRate,
           abs(actualNominalSampleRate - inputFormat.sampleRate) > 0.5 {
            return "The microphone device and audio engine sample rates have not settled"
        }
        return nil
    }
}

struct StreamingMicRouteStabilityGate: Sendable {
    enum Decision: Equatable, Sendable {
        case waiting(String)
        case ready(StreamingMicRouteFingerprint)
    }

    private let requiredMatchingObservations: Int
    private var lastValidFingerprint: StreamingMicRouteFingerprint?
    private var matchingObservationCount = 0

    init(requiredMatchingObservations: Int = 2) {
        precondition(requiredMatchingObservations > 0)
        self.requiredMatchingObservations = requiredMatchingObservations
    }

    mutating func observe(_ fingerprint: StreamingMicRouteFingerprint) -> Decision {
        if let failure = fingerprint.validationFailure {
            lastValidFingerprint = nil
            matchingObservationCount = 0
            return .waiting(failure)
        }

        if fingerprint == lastValidFingerprint {
            matchingObservationCount += 1
        } else {
            lastValidFingerprint = fingerprint
            matchingObservationCount = 1
        }

        guard matchingObservationCount >= requiredMatchingObservations else {
            return .waiting("Waiting for the microphone route to remain stable")
        }
        return .ready(fingerprint)
    }
}
