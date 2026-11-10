import AudioToolbox
import Cocoa

/// Loads the plugin's native Cocoa view (JUCE AUv2 view) using the
/// AUCustomViewBase informal protocol: `uiViewForAudioUnit:withSize:`.
enum PluginViewLoader {

    static func loadView(rawUnit: AudioUnit, size: NSSize) -> NSView? {
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioUnitGetPropertyInfo(
            rawUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global, 0,
            &dataSize, &writable)
        guard infoStatus == noErr,
              dataSize >= UInt32(MemoryLayout<AudioUnitCocoaUIInfo>.size)
        else { return nil }

        var info = AudioUnitCocoaUIInfo(
            mCocoaAUViewBundlePath: "" as CFString,
            mCocoaAUViewClassName: "" as CFString)
        var sizeIn = UInt32(MemoryLayout<AudioUnitCocoaUIInfo>.size)
        let getStatus = AudioUnitGetProperty(
            rawUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global, 0,
            &info, &sizeIn)
        guard getStatus == noErr else { return nil }

        let classObject = info.mCocoaAUViewClassName as AnyObject
        guard let className = classObject as? NSString else { return nil }
        guard let viewClass = NSClassFromString(className as String) else { return nil }

        let uiSelector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard class_respondsToSelector(viewClass, uiSelector),
              let uiImplementation = class_getMethodImplementation(viewClass, uiSelector)
        else { return nil }

        let initSelector = NSSelectorFromString("init")
        guard let initImplementation = class_getMethodImplementation(viewClass, initSelector),
              let allocated = class_createInstance(viewClass, 0) as AnyObject?
        else { return nil }

        typealias InitFunction = @convention(c) (AnyObject, Selector) -> AnyObject?
        let initFunction = unsafeBitCast(initImplementation, to: InitFunction.self)
        guard let instance = initFunction(allocated, initSelector) else { return nil }

        typealias UIFunction = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let uiFunction = unsafeBitCast(uiImplementation, to: UIFunction.self)
        guard let view = uiFunction(instance, uiSelector, rawUnit, size)?.takeUnretainedValue()
        else { return nil }

        view.autoresizingMask = [.width, .height]
        return view
    }
}
