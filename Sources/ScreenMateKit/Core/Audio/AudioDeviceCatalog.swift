import CoreAudio
import Foundation
import ScreenMateCore

public struct AudioInputDevice: Sendable, Identifiable, Hashable {
    /// CoreAudio device UID. Stable across reboots, so it is what gets saved.
    public let id: String
    public let name: String
    public let deviceID: AudioDeviceID
    public let isDefault: Bool

    public init(id: String, name: String, deviceID: AudioDeviceID, isDefault: Bool) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.isDefault = isDefault
    }
}

/// Enumerates microphones through CoreAudio.
///
/// CoreAudio rather than `AVCaptureDevice` for two reasons: the device-type
/// discovery API for microphones is macOS 14+, and `AVAudioEngine` needs an
/// `AudioDeviceID` to switch inputs, which only CoreAudio provides.
public struct AudioDeviceCatalog: Sendable {
    public init() {}

    public func inputDevices() -> [AudioInputDevice] {
        let defaultID = Self.defaultInputDeviceID()
        return Self.allDeviceIDs().compactMap { deviceID in
            guard Self.hasInputStreams(deviceID) else { return nil }
            guard let uid = Self.stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            let name = Self.stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(
                id: uid,
                name: name,
                deviceID: deviceID,
                isDefault: deviceID == defaultID
            )
        }
    }

    /// Resolves a saved UID back to a live device, or `nil` if it was unplugged.
    public func device(forUID uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.id == uid }
    }

    public func defaultInputDevice() -> AudioInputDevice? {
        inputDevices().first { $0.isDefault } ?? inputDevices().first
    }

    public var hasAnyInput: Bool { !inputDevices().isEmpty }

    // MARK: - CoreAudio plumbing

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceID == 0 ? nil : deviceID
    }

    /// A device counts as a microphone when it has at least one input channel.
    static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        let pointer = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return pointer.contains { $0.mNumberChannels > 0 }
    }

    static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
