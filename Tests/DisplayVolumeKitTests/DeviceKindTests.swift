import CoreAudio
import Testing
@testable import DisplayVolumeKit

@Suite("Output device kind classification")
struct DeviceKindTests {

    // deviceID 0 (unknown) makes the data-source probe a no-op, so these
    // exercise the name/transport rules deterministically.
    private func classify(_ name: String, _ transport: UInt32) -> OutputDeviceKind {
        AudioDeviceManager.classify(deviceID: AudioObjectID(kAudioObjectUnknown),
                                    name: name, transport: transport)
    }

    @Test("displays, speakers, and transports map to their glyph kinds")
    func transportMapping() {
        #expect(classify("32X3A", kAudioDeviceTransportTypeDisplayPort) == .display)
        #expect(classify("LG HDR 4K", kAudioDeviceTransportTypeHDMI) == .display)
        #expect(classify("MacBook Air Speakers", kAudioDeviceTransportTypeBuiltIn) == .builtinSpeaker)
        #expect(classify("JBL Flip", kAudioDeviceTransportTypeBluetooth) == .bluetoothSpeaker)
        #expect(classify("Living Room", kAudioDeviceTransportTypeAirPlay) == .airPlay)
        #expect(classify("Scarlett 2i2", kAudioDeviceTransportTypeUSB) == .genericSpeaker)
    }

    @Test("headphone-ish names win over transport")
    func headphoneNames() {
        #expect(classify("Sony WH-1000XM5 Headphones", kAudioDeviceTransportTypeBluetooth) == .headphones)
        #expect(classify("USB Headset", kAudioDeviceTransportTypeUSB) == .headphones)
        #expect(classify("Galaxy Buds", kAudioDeviceTransportTypeBluetooth) == .headphones)
        #expect(classify("External Headphones", kAudioDeviceTransportTypeBuiltIn) == .headphones)
    }

    @Test("AirPods variants get their specific glyphs")
    func airPodsVariants() {
        #expect(classify("Alec's AirPods Pro", kAudioDeviceTransportTypeBluetooth) == .airPodsPro)
        #expect(classify("AirPods Max", kAudioDeviceTransportTypeBluetooth) == .airPodsMax)
        #expect(classify("Alec's AirPods", kAudioDeviceTransportTypeBluetooth) == .airPods)
    }

    @Test("every kind produces a non-empty menu-bar symbol in both states")
    func symbolsNonEmpty() {
        let kinds: [OutputDeviceKind] = [.builtinSpeaker, .headphones, .airPods,
                                         .airPodsPro, .airPodsMax, .display,
                                         .bluetoothSpeaker, .airPlay, .genericSpeaker]
        for kind in kinds {
            #expect(!kind.menuBarSymbol(active: true).isEmpty)
            #expect(!kind.menuBarSymbol(active: false).isEmpty)
        }
    }
}
