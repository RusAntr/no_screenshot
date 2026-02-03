import Flutter
import UIKit
import ScreenProtectorKit
public class IOSNoScreenshotPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var screenProtectorKit: ScreenProtectorKit? = nil
    private weak var attachedWindow: UIWindow? = nil
    private var attachRetryScheduled: Bool = false
    private static var methodChannel: FlutterMethodChannel? = nil
    private static var eventChannel: FlutterEventChannel? = nil
    private static var preventScreenShot: Bool = false
    private var eventSink: FlutterEventSink? = nil
    private var lastSharedPreferencesState: String = ""
    private var hasSharedPreferencesChanged: Bool = false
    private static let ENABLESCREENSHOT = false
    private static let DISABLESCREENSHOT = true
    private static let preventScreenShotKey = "preventScreenShot"
    private static let methodChannelName = "com.flutterplaza.no_screenshot_methods"
    private static let eventChannelName = "com.flutterplaza.no_screenshot_streams"
    private static let screenshotPathPlaceholder = "screenshot_path_placeholder"

    init(screenProtectorKit: ScreenProtectorKit? = nil) {
        self.screenProtectorKit = screenProtectorKit
        super.init()

        // Restore the saved state from UserDefaults
        let blocked = UserDefaults.standard.bool(forKey: IOSNoScreenshotPlugin.preventScreenShotKey)
        IOSNoScreenshotPlugin.preventScreenShot = blocked
        updateSharedPreferencesState("")
        // Window may not be ready during plugin init; attach/apply when the app becomes active.
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())

        let instance = IOSNoScreenshotPlugin()

        registrar.addMethodCallDelegate(instance, channel: methodChannel!)
        eventChannel?.setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
    }
    public func applicationWillResignActive(_ application: UIApplication) {
        persistState()
        detachKit()
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        fetchPersistedState()
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        fetchPersistedState()
    }
    public func applicationDidEnterBackground(_ application: UIApplication) {
        persistState()
        detachKit()
    }
    public func applicationWillTerminate(_ application: UIApplication) {
        persistState()
    }
    func persistState() {
        // Persist the state when changed
        UserDefaults.standard.set(IOSNoScreenshotPlugin.preventScreenShot, forKey: IOSNoScreenshotPlugin.preventScreenShotKey)
        print("Persisted state: \(IOSNoScreenshotPlugin.preventScreenShot)")
        updateSharedPreferencesState("")
    }
    func fetchPersistedState() {
        // Restore the saved state from UserDefaults
        let blocked = UserDefaults.standard.bool(forKey: IOSNoScreenshotPlugin.preventScreenShotKey)
        updateScreenshotState(isScreenshotBlocked: blocked)
        print("Fetched state: \(blocked)")
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "screenshotOff":
            shotOff()
            result(true)
        case "screenshotOn":
            shotOn()
            result(true)
        case "toggleScreenshot":
            IOSNoScreenshotPlugin.preventScreenShot ? shotOn() : shotOff()
            result(true)
        case "startScreenshotListening":
            startListening()
            result("Listening started")
        case "stopScreenshotListening":
            stopListening()
            result("Listening stopped")
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    private func shotOff() {
        updateScreenshotState(isScreenshotBlocked: IOSNoScreenshotPlugin.DISABLESCREENSHOT)
        persistState()
    }
    private func shotOn() {
        updateScreenshotState(isScreenshotBlocked: IOSNoScreenshotPlugin.ENABLESCREENSHOT)
        persistState()
    }
    private func startListening() {
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotDetected), name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        persistState()
    }
    private func stopListening() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        persistState()
    }
    @objc private func screenshotDetected() {
        print("Screenshot detected")
        updateSharedPreferencesState(IOSNoScreenshotPlugin.screenshotPathPlaceholder)
    }

    private func updateScreenshotState(isScreenshotBlocked: Bool) {
        IOSNoScreenshotPlugin.preventScreenShot = isScreenshotBlocked
        updateSharedPreferencesState("")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !isScreenshotBlocked {
                if let kit = self.screenProtectorKit {
                    kit.disablePreventScreenshot()
                    kit.removeAllObserver()
                }
                self.screenProtectorKit = nil
                self.attachedWindow = nil
                return
            }

            guard self.ensureKitAttached() else { return }
            guard let kit = self.screenProtectorKit else { return }

            // Reset first to reduce cases where the protection overlay gets "stuck" after app switching.
            kit.disablePreventScreenshot()
            kit.enabledPreventScreenshot()
        }
    }
    private func updateSharedPreferencesState(_ screenshotData: String) {
        let map: [String: Any] = [
            "is_screenshot_on": IOSNoScreenshotPlugin.preventScreenShot,
            "screenshot_path": screenshotData,
            "was_screenshot_taken": !screenshotData.isEmpty
        ]
        let jsonString = convertMapToJsonString(map)
        if lastSharedPreferencesState != jsonString {
            hasSharedPreferencesChanged = true
            lastSharedPreferencesState = jsonString
        }
    }
    private func convertMapToJsonString(_ map: [String: Any]) -> String {
        if let jsonData = try? JSONSerialization.data(withJSONObject: map, options: .prettyPrinted) {
            return String(data: jsonData, encoding: .utf8) ?? ""
        }
        return ""
    }
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.screenshotStream()
        }
        return nil
    }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
    private func screenshotStream() {
        guard eventSink != nil else { return }
        if hasSharedPreferencesChanged {
            eventSink?(lastSharedPreferencesState)
            hasSharedPreferencesChanged = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.screenshotStream()
        }
    }

    private func findBestWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let foregroundScenes = scenes.filter {
                $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
            }

            let foregroundWindows = foregroundScenes.flatMap { $0.windows }
            if let key = foregroundWindows.first(where: { $0.isKeyWindow }) { return key }
            if let visible = foregroundWindows.first(where: { !$0.isHidden && $0.alpha > 0 }) { return visible }
            return nil
        } else {
            return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
        }
    }

    private func scheduleAttachRetryIfNeeded() {
        guard !attachRetryScheduled else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        guard IOSNoScreenshotPlugin.preventScreenShot else { return }
        attachRetryScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.attachRetryScheduled = false
            guard UIApplication.shared.applicationState != .background else { return }
            // Re-apply the state; this will try attaching again.
            self.updateScreenshotState(isScreenshotBlocked: IOSNoScreenshotPlugin.preventScreenShot)
        }
    }

    private func ensureKitAttached() -> Bool {
        // Avoid touching UIKit windows / ScreenProtectorKit while the app is backgrounding/backgrounded.
        // On simulator this can be especially crash-prone during transitions.
        guard UIApplication.shared.applicationState == .active else {
            scheduleAttachRetryIfNeeded()
            return false
        }

        guard let window = findBestWindow() else {
            scheduleAttachRetryIfNeeded()
            return false
        }

        if attachedWindow === window, screenProtectorKit != nil { return true }

        // Work around: ScreenProtectorKit adds a new UI component to disable screenshots.
        // The new instance will not be able to disable it anymore, therefore we need to turn it off using the old instance.
        if let existing = screenProtectorKit {
            existing.disablePreventScreenshot()
            existing.removeAllObserver()
        }

        let kit = ScreenProtectorKit(window: window)
        kit.configurePreventionScreenshot()
        screenProtectorKit = kit
        attachedWindow = window
        return true
    }

    private func detachKit() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let kit = self.screenProtectorKit {
                kit.disablePreventScreenshot()
                kit.removeAllObserver()
            }
            self.screenProtectorKit = nil
            self.attachedWindow = nil
        }
    }


    deinit {
        screenProtectorKit?.removeAllObserver()
    }
}
