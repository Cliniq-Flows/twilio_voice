import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit
import UserNotifications

public class SwiftTwilioVoicePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, PKPushRegistryDelegate, NotificationDelegate, CallDelegate, AVAudioPlayerDelegate, CXProviderDelegate {
    
    final let defaultCallKitIcon = "callkit_icon"
    var callKitIcon: String?
    
    var _result: FlutterResult?
    private var eventSink: FlutterEventSink?
    
    let kRegistrationTTLInDays = 365
    
    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kClientList = "TwilioContactList"
    private var clients: [String:String]!
    
    var accessToken:String?
    var identity = "alice"
    var callTo: String = "error"
    var defaultCaller = "Unknown Caller"
    var deviceToken: Data? {
        get { UserDefaults.standard.data(forKey: kCachedDeviceToken) }
        set { UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken) }
    }
    var callArgs: [String: AnyObject] = [:]
    
    var voipRegistry: PKPushRegistry
    var incomingPushCompletionCallback: (() -> Swift.Void?)? = nil
    
    // Store active call invites using a String key (preferably callSid)
    var activeCallInvites: [String: CallInvite] = [:]
    // Active calls are keyed by their UUID.
    var activeCalls: [UUID: Call] = [:]
    
    var callKitCompletionCallback: ((Bool) -> Swift.Void?)? = nil
    var audioDevice: DefaultAudioDevice = DefaultAudioDevice()
    
    var callKitProvider: CXProvider
    var callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    var callOutgoing: Bool = false
    
    static var appName: String {
        return (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
    }
    
    public override init() {
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        let configuration = CXProviderConfiguration(localizedName: SwiftTwilioVoicePlugin.appName)
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 2
        let defaultIcon = UserDefaults.standard.string(forKey: defaultCallKitIcon) ?? defaultCallKitIcon
        
        clients = UserDefaults.standard.object(forKey: kClientList) as? [String:String] ?? [:]
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        super.init()
        
        callKitProvider.setDelegate(self, queue: nil)
        _ = updateCallKitIcon(icon: defaultIcon)
        
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = Set([PKPushType.voIP])
        
        let appDelegate = UIApplication.shared.delegate
        guard let controller = appDelegate?.window??.rootViewController as? FlutterViewController else {
            fatalError("rootViewController is not type FlutterViewController")
        }
        let registrar = controller.registrar(forPlugin: "twilio_voice")
        if let unwrappedRegistrar = registrar {
            let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: unwrappedRegistrar.messenger())
            eventChannel.setStreamHandler(self)
        }
    }
    
    deinit {
        callKitProvider.invalidate()
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftTwilioVoicePlugin()
        let methodChannel = FlutterMethodChannel(name: "twilio_voice/messages", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        registrar.addApplicationDelegate(instance)
    }
    
    public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
        _result = result
        let arguments = flutterCall.arguments as! [String: AnyObject]
        
        if flutterCall.method == "tokens" {
            guard let token = arguments["accessToken"] as? String else { return }
            self.accessToken = token
            if let deviceToken = deviceToken, let token = accessToken {
                self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                    if let error = error {
                        self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    } else {
                        self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                    }
                }
            }
        } else if flutterCall.method == "makeCall" {
            guard let callTo = arguments["To"] as? String,
                  let callFrom = arguments["From"] as? String else { return }
            self.callArgs = arguments
            self.callOutgoing = true
            if let accessToken = arguments["accessToken"] as? String {
                self.accessToken = accessToken
            }
            self.callTo = callTo
            self.identity = callFrom
            makeCall(to: callTo)
        }
        // Example: toggleMute requires a "callUUID" string.
        else if flutterCall.method == "toggleMute" {
            guard let muted = arguments["muted"] as? Bool,
                  let callUUIDString = arguments["callUUID"] as? String,
                  let uuid = UUID(uuidString: callUUIDString),
                  let call = activeCalls[uuid] else {
                      result(FlutterError(code: "MUTE_ERROR", message: "No call found for mute", details: nil))
                      return
                  }
            call.isMuted = muted
            eventSink?(muted ? "Mute" : "Unmute")
        }
        else if flutterCall.method == "isMuted" {
            if let callUUIDString = arguments["callUUID"] as? String,
               let uuid = UUID(uuidString: callUUIDString),
               let call = activeCalls[uuid] {
                result(call.isMuted)
            } else {
                result(false)
            }
        }
        else if flutterCall.method == "toggleSpeaker" {
            guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else { return }
            toggleAudioRoute(toSpeaker: speakerIsOn)
            eventSink?(speakerIsOn ? "Speaker On" : "Speaker Off")
        }
        else if flutterCall.method == "isOnSpeaker" {
            result(isSpeakerOn())
        }
        else if flutterCall.method == "toggleBluetooth" {
            guard let bluetoothOn = arguments["bluetoothOn"] as? Bool else { return }
            eventSink?(bluetoothOn ? "Bluetooth On" : "Bluetooth Off")
        }
        else if flutterCall.method == "isBluetoothOn" {
            result(isBluetoothOn())
        }
        else if flutterCall.method == "call-sid" {
            let callSIDs = activeCalls.keys.map { $0.uuidString }
            result(callSIDs)
            return
        }
        else if flutterCall.method == "isOnCall" {
            result(!activeCalls.isEmpty)
            return
        }
        else if flutterCall.method == "sendDigits" {
            guard let digits = arguments["digits"] as? String,
                  let callUUIDString = arguments["callUUID"] as? String,
                  let uuid = UUID(uuidString: callUUIDString),
                  let call = activeCalls[uuid] else { return }
            call.sendDigits(digits)
        }
        else if flutterCall.method == "holdCall" {
            guard let shouldHold = arguments["shouldHold"] as? Bool,
                  let callUUIDString = arguments["callUUID"] as? String,
                  let uuid = UUID(uuidString: callUUIDString) else { return }
            setHoldState(forCall: uuid, shouldHold: shouldHold)
        }
        else if flutterCall.method == "hangUp" {
            guard let callUUIDString = arguments["callUUID"] as? String,
                  let uuid = UUID(uuidString: callUUIDString) else { return }
            hangUpCall(with: uuid)
        }
        result(true)
    }
    
    /// Updates the CallKit provider configuration with a new icon.
    func updateCallKitIcon(icon: String) -> Bool {
        if let newIcon = UIImage(named: icon) {
            var configuration = callKitProvider.configuration
            configuration.iconTemplateImageData = newIcon.pngData()
            callKitProvider.configuration = configuration
            UserDefaults.standard.set(icon, forKey: defaultCallKitIcon)
            return true
        }
        return false
    }
    
    func makeCall(to: String) {
        let uuid = UUID()
        checkRecordPermission { permissionGranted in
            if !permissionGranted {
                let alertController = UIAlertController(title: String(format: NSLocalizedString("mic_permission_title", comment: ""), SwiftTwilioVoicePlugin.appName),
                                                        message: NSLocalizedString("mic_permission_subtitle", comment: ""),
                                                        preferredStyle: .alert)
                let continueWithMic = UIAlertAction(title: NSLocalizedString("btn_continue_no_mic", comment: ""), style: .default) { action in
                    self.performStartCallAction(uuid: uuid, handle: to)
                }
                alertController.addAction(continueWithMic)
                let goToSettings = UIAlertAction(title: NSLocalizedString("btn_settings", comment: ""), style: .default) { action in
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                              options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: false],
                                              completionHandler: nil)
                }
                alertController.addAction(goToSettings)
                let cancel = UIAlertAction(title: NSLocalizedString("btn_cancel", comment: ""), style: .cancel, handler: nil)
                alertController.addAction(cancel)
                guard let currentViewController = UIApplication.shared.keyWindow?.topMostViewController() else { return }
                currentViewController.present(alertController, animated: true, completion: nil)
            } else {
                self.performStartCallAction(uuid: uuid, handle: to)
            }
        }
    }
    
    func checkRecordPermission(completion: @escaping (_ permissionGranted: Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }
    
    // MARK: PKPushRegistryDelegate
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType:", isError: false)
        if type != .voIP { return }
        guard registrationRequired() || deviceToken != credentials.token else { return }
        let deviceToken = credentials.token
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
        if let token = accessToken {
            TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    self.sendPhoneCallEvents(description: "DEVICETOKEN|\(String(decoding: deviceToken, as: UTF8.self))", isError: false)
                } else {
                    self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                }
            }
        }
        self.deviceToken = deviceToken
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
    }
    
    func registrationRequired() -> Bool {
        guard let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate) as? Date else { return true }
        let date = Date()
        var components = DateComponents()
        components.setValue(kRegistrationTTLInDays/2, for: .day)
        let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated)!
        return expirationDate.compare(date) != .orderedDescending
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didInvalidatePushTokenForType:", isError: false)
        if type != .voIP { return }
        self.unregister()
    }
    
    func unregister() {
        guard let deviceToken = deviceToken, let token = accessToken else { return }
        unregisterTokens(token: token, deviceToken: deviceToken)
    }
    
    func unregisterTokens(token: String, deviceToken: Data) {
        TwilioVoiceSDK.unregister(accessToken: token, deviceToken: deviceToken) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|An error occurred while unregistering: \(error.localizedDescription)", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Successfully unregistered from VoIP push notifications.", isError: false)
            }
        }
        UserDefaults.standard.removeObject(forKey: kCachedDeviceToken)
        UserDefaults.standard.removeObject(forKey: kCachedBindingDate)
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:", isError: false)
        if type == .voIP {
            TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:completion:", isError: false)
        if type == .voIP {
            TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
        if let version = Float(UIDevice.current.systemVersion), version < 13.0 {
            self.incomingPushCompletionCallback = completion
        } else {
            completion()
        }
    }
    
    func incomingPushHandled() {
        if let completion = self.incomingPushCompletionCallback {
            self.incomingPushCompletionCallback = nil
            completion()
        }
    }
    
    // MARK: NotificationDelegate – Handling incoming call invites.
    public func callInviteReceived(callInvite: CallInvite) {
        self.sendPhoneCallEvents(description: "LOG|callInviteReceived:", isError: false)
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        let from = callInvite.customParameters?["firstname"] as? String ?? ""
        let fromx = callInvite.customParameters?["lastname"] as? String ?? ""
        var fromx1 = callInvite.from ?? ""
        fromx1 = fromx1.replacingOccurrences(of: "client:", with: "")
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(callInvite.to)|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        // Use callSid as key if available; otherwise, use uuid string.
        let key = callInvite.callSid.isEmpty ? callInvite.uuid.uuidString : callInvite.callSid
        activeCallInvites[key] = callInvite
        reportIncomingCall(from: from, fromx: fromx, fromx1: fromx1, uuid: callInvite.uuid)
    }
    
    func formatCustomParams(params: [String:Any]?) -> String {
        guard let customParameters = params else { return "" }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: customParameters)
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                return "|\(jsonStr)"
            }
        } catch {
            print("unable to send custom parameters")
        }
        return ""
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        self.sendPhoneCallEvents(description: "Missed Call", isError: false)
        self.sendPhoneCallEvents(description: "LOG|cancelledCallInviteCanceled:", isError: false)
        self.showMissedCallNotification(from: "\(cancelledCallInvite.customParameters?["firstname"] as? String ?? "") \(cancelledCallInvite.customParameters?["lastname"] as? String ?? "")", to: cancelledCallInvite.to)
        // Look up the invite using callSid as key.
        let key = cancelledCallInvite.callSid.isEmpty ? cancelledCallInvite.uuid.uuidString : cancelledCallInvite.callSid
        if let invite = activeCallInvites[key] {
            if let uuid = invite.uuid {
                performEndCallAction(uuid: uuid)
            }
            activeCallInvites.removeValue(forKey: key)
        }
    }
    
    func showMissedCallNotification(from: String?, to: String?) {
        guard UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true else { return }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                let content = UNMutableNotificationContent()
                var userName: String?
                if var from = from {
                    from = from.replacingOccurrences(of: "client:", with: "")
                    content.userInfo = ["type": "twilio-missed-call", "From": from]
                    if let to = to {
                        content.userInfo["To"] = to
                    }
                    userName = self.clients[from]
                }
                let title = userName ?? self.clients["defaultCaller"] ?? self.defaultCaller
                content.title = String(format: NSLocalizedString("notification_missed_call", comment: ""), title)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                notificationCenter.add(request) { error in
                    if let error = error {
                        print("Notification Error: ", error)
                    }
                }
            }
        }
    }
    
    // MARK: CallDelegate
    public func callDidStartRinging(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = call.from ?? self.identity
        let to = call.to ?? self.callTo
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(to)|\(direction)", isError: false)
    }
    
    public func callDidConnect(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = call.from ?? self.identity
        let to = call.to ?? self.callTo
        self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)
        callKitCompletionCallback?(true)
        toggleAudioRoute(toSpeaker: false)
    }
    
    public func call(call: Call, isReconnectingWithError error: Error) {
        self.sendPhoneCallEvents(description: "Reconnecting", isError: false)
    }
    
    public func callDidReconnect(call: Call) {
        self.sendPhoneCallEvents(description: "Reconnected", isError: false)
    }
    
    public func callDidFailToConnect(call: Call, error: Error) {
        self.sendPhoneCallEvents(description: "LOG|Call failed to connect: \(error.localizedDescription)", isError: false)
        self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        if error.localizedDescription.contains("Access Token expired") {
            self.sendPhoneCallEvents(description: "DEVICETOKEN", isError: false)
        }
        callKitCompletionCallback?(false)
        if let uuid = call.uuid {
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: CXCallEndedReason.failed)
        }
        callDisconnected(call: call)
    }
    
    public func callDidDisconnect(call: Call, error: Error?) {
        self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        if let error = error {
            self.sendPhoneCallEvents(description: "Call Failed: \(error.localizedDescription)", isError: true)
        }
        if !self.userInitiatedDisconnect {
            var reason = CXCallEndedReason.remoteEnded
            self.sendPhoneCallEvents(description: "LOG|User initiated disconnect", isError: false)
            if error != nil {
                reason = .failed
            }
            if let uuid = call.uuid {
                callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            }
        }
        callDisconnected(call: call)
    }
    
    func callDisconnected(call: Call) {
        self.sendPhoneCallEvents(description: "LOG|Call Disconnected", isError: false)
        if let uuid = call.uuid {
            activeCalls.removeValue(forKey: uuid)
        }
        // Remove invite using uuid string as fallback.
        activeCallInvites.removeValue(forKey: call.uuid?.uuidString ?? "")
        self.callOutgoing = false
        self.userInitiatedDisconnect = false
    }
    
    func isSpeakerOn() -> Bool {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        for output in currentRoute.outputs {
            if output.portType == AVAudioSession.Port.builtInSpeaker {
                return true
            }
        }
        return false
    }
    
    func isBluetoothOn() -> Bool {
        return false
    }
    
    func toggleAudioRoute(toSpeaker: Bool) {
        audioDevice.block = {
            DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
            do {
                if toSpeaker {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                } else {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                }
            } catch {
                self.sendPhoneCallEvents(description: "LOG|\(error.localizedDescription)", isError: false)
            }
        }
        audioDevice.block()
    }
    
    // MARK: CXProviderDelegate
    public func providerDidReset(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|providerDidReset:", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func providerDidBegin(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|providerDidBegin", isError: false)
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|provider:didActivateAudioSession:", isError: false)
        audioDevice.isEnabled = true
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|provider:didDeactivateAudioSession:", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:timedOutPerformingAction:", isError: false)
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performStartCallAction:", isError: false)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        performVoiceCall(uuid: action.callUUID, client: "") { success in
            if success {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() successful", isError: false)
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            } else {
                self.sendPhoneCallEvents(description: "LOG|provider:performVoiceCall() failed", isError: false)
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performAnswerCallAction:", isError: false)
        performAnswerVoiceCall(uuid: action.callUUID) { success in
            if success {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() successful", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() failed:", isError: false)
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction:", isError: false)
        if let call = activeCalls[action.callUUID] {
            // If there's an invite associated (using uuid string as fallback), reject it.
            if activeCallInvites[action.callUUID.uuidString] != nil {
                activeCallInvites[action.callUUID.uuidString]?.reject()
                activeCallInvites.removeValue(forKey: action.callUUID.uuidString)
            } else {
                call.disconnect()
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetHeldAction:", isError: false)
        if let call = activeCalls[action.callUUID] {
            call.isOnHold = action.isOnHold
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetMutedAction:", isError: false)
        if let call = activeCalls[action.callUUID] {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    func performStartCallAction(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        let transaction = CXTransaction(action: startCallAction)
        callKitCallController.request(transaction) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                return
            }
            self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request successful", isError: false)
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.localizedCallerName = self.clients[handle] ?? self.clients["defaultCaller"] ?? self.defaultCaller
            callUpdate.supportsDTMF = false
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false
            self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
        }
    }
    
    func reportIncomingCall(from: String, fromx: String, fromx1: String, uuid: UUID) {
        let firstname = from.capitalized
        let lastname = fromx.capitalized
        let number = fromx1
        let combine = "\(firstname) \(lastname)"
        let finale = combine.trimmingCharacters(in: .whitespaces).isEmpty ? number : combine
        let callHandle = CXHandle(type: .generic, value: finale.capitalized)
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.localizedCallerName = finale
        callUpdate.supportsDTMF = true
        callUpdate.supportsHolding = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|Failed to report incoming call successfully: \(error.localizedDescription).", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Incoming call successfully reported.", isError: false)
            }
        }
    }
    
    func performEndCallAction(uuid: UUID) {
        self.sendPhoneCallEvents(description: "LOG|performEndCallAction method invoked", isError: false)
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        callKitCallController.request(transaction) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "End Call Failed: \(error.localizedDescription).", isError: true)
            } else {
                self.sendPhoneCallEvents(description: "Call Ended", isError: false)
            }
        }
    }
    
    func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Swift.Void) {
        guard let token = accessToken else {
            completionHandler(false)
            return
        }
        let connectOptions = ConnectOptions(accessToken: token) { builder in
            for (key, value) in self.callArgs {
                if key != "From" {
                    builder.params[key] = "\(value)"
                }
            }
            builder.uuid = uuid
        }
        let theCall = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
        activeCalls[uuid] = theCall
        self.callKitCompletionCallback = completionHandler
    }
    
    func performAnswerVoiceCall(uuid: UUID, completionHandler: @escaping (Bool) -> Swift.Void) {
        if let callInvite = activeCallInvites.first(where: { $0.value.uuid == uuid })?.value {
            let acceptOptions = AcceptOptions(callInvite: callInvite) { builder in
                builder.uuid = callInvite.uuid
            }
            self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call", isError: false)
            let theCall = callInvite.accept(options: acceptOptions, delegate: self)
            self.sendPhoneCallEvents(description: "Answer|\(theCall.from ?? "")|\(theCall.to ?? "")\(formatCustomParams(params: callInvite.customParameters))", isError: false)
            activeCalls[uuid] = theCall
            self.callKitCompletionCallback = completionHandler
            activeCallInvites.removeValue(forKey: callInvite.callSid.isEmpty ? callInvite.uuid.uuidString : callInvite.callSid)
            if #available(iOS 13, *) {
                // iOS 13 and above handle push completion differently.
            } else {
                self.incomingPushHandled()
            }
        } else {
            self.sendPhoneCallEvents(description: "LOG|No CallInvite matches the UUID", isError: false)
            completionHandler(false)
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        NotificationCenter.default.addObserver(self, selector: #selector(CallDelegate.callDidDisconnect), name: NSNotification.Name(rawValue: "PhoneCallEvent"), object: nil)
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        return nil
    }
    
    private func sendPhoneCallEvents(description: String, isError: Bool) {
        NSLog(description)
        guard let eventSink = eventSink else { return }
        if isError {
            eventSink(FlutterError(code: "unavailable", message: description, details: nil))
        } else {
            eventSink(description)
        }
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "twilio-missed-call", let user = userInfo["From"] as? String {
            self.callTo = user
            if let to = userInfo["To"] as? String {
                self.identity = to
            }
            makeCall(to: callTo)
            completionHandler()
            self.sendPhoneCallEvents(description: "ReturningCall|\(identity)|\(user)|Outgoing", isError: false)
        }
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "twilio-missed-call" {
            completionHandler([.alert])
        }
    }
}

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        guard let rootViewController = self.rootViewController else { return nil }
        return topViewController(for: rootViewController)
    }
    
    func topViewController(for rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController = rootViewController else { return nil }
        guard let presentedViewController = rootViewController.presentedViewController else { return rootViewController }
        switch presentedViewController {
        case is UINavigationController:
            let navigationController = presentedViewController as! UINavigationController
            return topViewController(for: navigationController.viewControllers.last)
        case is UITabBarController:
            let tabBarController = presentedViewController as! UITabBarController
            return topViewController(for: tabBarController.selectedViewController)
        default:
            return topViewController(for: presentedViewController)
        }
    }
}

extension UserDefaults {
    public func optionalBool(forKey defaultName: String) -> Bool? {
        if let value = value(forKey: defaultName) {
            return value as? Bool
        }
        return nil
    }
}

extension SwiftTwilioVoicePlugin {
    func setHoldState(forCall uuid: UUID, shouldHold: Bool) {
        guard let call = activeCalls[uuid] else {
            sendPhoneCallEvents(description: "No call found for UUID \(uuid.uuidString) to set hold", isError: true)
            return
        }
        if call.isOnHold != shouldHold {
            call.isOnHold = shouldHold
            eventSink?(shouldHold ? "Hold" : "Unhold")
        }
    }
    
    func hangUpCall(with uuid: UUID) {
        guard let _ = activeCalls[uuid] else {
            sendPhoneCallEvents(description: "No call found for UUID \(uuid.uuidString) to hang up", isError: true)
            return
        }
        userInitiatedDisconnect = true
        performEndCallAction(uuid: uuid)
    }
}
