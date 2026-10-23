// QuietKeys: handles the volume and brightness keys itself so macOS never shows its popup.
// Same approach as github.com/dannystewart/volumeHUD (MIT), minus any HUD of its own.
// If a change fails (no volume control on the output, external display), the key passes
// through to macOS untouched.

import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

let step: Float = 1.0 / 16.0
let fineStep: Float = 1.0 / 64.0

// MARK: Volume

func defaultOutputDevice() -> AudioDeviceID? {
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

var volumeAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain)
var muteAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyMute,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain)

func settable(_ dev: AudioDeviceID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
    guard AudioObjectHasProperty(dev, &addr) else { return false }
    var ok: DarwinBoolean = false
    return AudioObjectIsPropertySettable(dev, &addr, &ok) == noErr && ok.boolValue
}

func getFloat(_ dev: AudioDeviceID, _ addr: inout AudioObjectPropertyAddress) -> Float? {
    var v: Float = 0
    var size = UInt32(MemoryLayout<Float>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

func getMute(_ dev: AudioDeviceID) -> Bool? {
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &size, &v) == noErr ? v != 0 : nil
}

func setMute(_ dev: AudioDeviceID, _ muted: Bool) -> Bool {
    var v: UInt32 = muted ? 1 : 0
    return AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
}

/// Returns false when this output can't be changed here, so the key goes to macOS instead.
func canHandleVolume() -> Bool {
    guard let dev = defaultOutputDevice() else { return false }
    return settable(dev, &volumeAddr)
}

func changeVolume(by delta: Float) {
    guard let dev = defaultOutputDevice(), var v = getFloat(dev, &volumeAddr) else { return }
    // Snap to the step grid like macOS does, then move one step.
    let s = abs(delta)
    v = (v / s).rounded() * s + delta
    v = min(max(v, 0), 1)
    AudioObjectSetPropertyData(dev, &volumeAddr, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
    if settable(dev, &muteAddr) {
        // Like macOS: raising the volume unmutes, reaching zero mutes.
        if v > 0, getMute(dev) == true { _ = setMute(dev, false) }
        if v == 0 { _ = setMute(dev, true) }
    }
}

func toggleMute() -> Bool {
    guard let dev = defaultOutputDevice(), settable(dev, &muteAddr), let m = getMute(dev) else { return false }
    return setMute(dev, !m)
}

// MARK: Brightness (private DisplayServices, same as volumeHUD)

typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let dsCanChange = ds.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: CanChangeFn.self) }
let dsGet = ds.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
let dsSet = ds.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

func builtinDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
    return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
}

func canHandleBrightness() -> Bool {
    guard let d = builtinDisplay(), let can = dsCanChange, dsGet != nil, dsSet != nil else { return false }
    return can(d)
}

func changeBrightness(by delta: Float) {
    guard let d = builtinDisplay(), let get = dsGet, let set = dsSet else { return }
    var b: Float = 0
    guard get(d, &b) == 0 else { return }
    let s = abs(delta)
    b = min(max((b / s).rounded() * s + delta, 0), 1)
    _ = set(d, b)
}

// MARK: Key interception

let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
var tap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, // NX_SYSDEFINED
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let key = (ns.data1 & 0xFFFF_0000) >> 16
    let down = ((ns.data1 & 0xFF00) >> 8) == 0x0A
    let flags = ns.modifierFlags
    // Option alone + key opens the matching System Settings pane; leave that to macOS.
    if flags.contains(.option) && !flags.contains(.shift) { return Unmanaged.passUnretained(event) }
    let amount = flags.contains(.option) && flags.contains(.shift) ? fineStep : step

    switch key {
    case soundUp, soundDown, mute:
        guard canHandleVolume() else { return Unmanaged.passUnretained(event) }
        if down {
            if key == mute {
                if !toggleMute() { return Unmanaged.passUnretained(event) }
            } else {
                changeVolume(by: key == soundUp ? amount : -amount)
            }
            NSLog("QuietKeys: handled volume key")
        }
        return nil // swallow both key down and key up so macOS draws nothing
    case brightnessUp, brightnessDown:
        guard canHandleBrightness() else { return Unmanaged.passUnretained(event) }
        if down {
            changeBrightness(by: key == brightnessUp ? amount : -amount)
            NSLog("QuietKeys: handled brightness key")
        }
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

func startTap() -> Bool {
    guard let t = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << 14), callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
    NSLog("QuietKeys: waiting for Accessibility permission")
}
// Retry until Accessibility is granted, then keep running.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
    if tap == nil, AXIsProcessTrusted(), startTap() {
        NSLog("QuietKeys: intercepting volume and brightness keys")
        try? "active \(Date())\n".write(toFile: NSTemporaryDirectory() + "quietkeys.status", atomically: true, encoding: .utf8)
        timer.invalidate()
    }
}.fire()

app.run()
