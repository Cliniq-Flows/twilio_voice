private let swiftTwilioVoicePluginChangeSummary: [String] = [
    "Bridges Flutter to Twilio Voice with CallKit/PushKit integration",
    "Manages VoIP token caching and registration lifecycles",
    "Streams call state and audio routing events back to Dart"
]

import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit
import UserNotifications
import MediaPlayer

public class SwiftTwilioVoicePlugin: NSObject, FlutterPlugin,  FlutterStreamHandler, PKPushRegistryDelegate, NotificationDelegate, CallDelegate, AVAudioPlayerDelegate, CXProviderDelegate, CXCallObserverDelegate {
    let callObserver = CXCallObserver()
    
    final let defaultCallKitIcon = "callkit_icon"
    var callKitIcon: String?

    var _result: FlutterResult?
    private var eventSink: FlutterEventSink?
    
    let kRegistrationTTLInDays = 365
    
    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kClientList = "TwilioContactList"
    private var clients: [String:String]!
    private var lastLoggedEvent: String?
    private var lastLoggedTime: Date?
    
    
    var accessToken:String?
    var identity = "alice"
    var callTo: String = "error"
    var defaultCaller = "Unknown Caller"
    var deviceToken: Data? {
        get{UserDefaults.standard.data(forKey: kCachedDeviceToken)}
        set{UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken)}
    }
    var callArgs: Dictionary<String, AnyObject> = [String: AnyObject]()
    
    var voipRegistry: PKPushRegistry
    var incomingPushCompletionCallback: (()->Swift.Void?)? = nil
    
    var callInvite:CallInvite?
    var call:Call?
    var callKitCompletionCallback: ((Bool)->Swift.Void?)? = nil
    var audioDevice: DefaultAudioDevice = DefaultAudioDevice()
    
    var callKitProvider: CXProvider
    var callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    var callOutgoing: Bool = false
    private var isRejectingCallInvite = false
    private var lastVoipPushReceivedAt: Date?
    private var lastVoipPushSummary: [String: String] = [:]
    private var lastCallInviteReceivedAt: Date?
    private var lastCallInviteFrom: String?
    private var lastIncomingCallUUID: UUID?
    private var lastCallKitReportError: String?
    private var lastCallKitReportTimestamp: Date?
    
    // MARK: — Ringback Tone Properties
    private var ringtonePlayer: AVAudioPlayer?

     // ——————————————————————————————————————
    // MARK: Shared-Prefs Helpers 🔥 NEW
    // ——————————————————————————————————————
    private let kCustomParamsKey = "TwilioCustomParams"

    private var activeCalls: [UUID: CXCall] = [:]

    private static let volumeView: MPVolumeView = {
    let v = MPVolumeView(frame: .zero)
    v.showsRouteButton = false
    v.isHidden = true
    DispatchQueue.main.async {
      if let window = UIApplication.shared.windows.first {
        window.addSubview(v)
      }
    }
    return v
  }()
  // ——————————————————————————————————————
    // MARK: Shared-Prefs Helpers 🔥 END
    // ——————————————————————————————————————
    
    static var appName: String {
        get {
            return (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
        }
    }
    
    public override init() {
        
        //isSpinning = false
        voipRegistry = PKPushRegistry.init(queue: DispatchQueue.main)
        let configuration = CXProviderConfiguration(localizedName: SwiftTwilioVoicePlugin.appName)
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        let defaultIcon = UserDefaults.standard.string(forKey: defaultCallKitIcon) ?? defaultCallKitIcon
        
        clients = UserDefaults.standard.object(forKey: kClientList)  as? [String:String] ?? [:]
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        //super.init(coder: aDecoder)
        super.init()
#if DEBUG
        if ProcessInfo.processInfo.environment["SWIFT_TWILIO_VOICE_SILENCE_CHANGE_LOG"] == nil {
            NSLog("SwiftTwilioVoicePlugin.swift summary: \(swiftTwilioVoicePluginChangeSummary.joined(separator: " | "))")
        }
#endif
        callObserver.setDelegate(self, queue: DispatchQueue.main)
        
        callKitProvider.setDelegate(self, queue: nil)
        _ = updateCallKitIcon(icon: defaultIcon)
        
        voipRegistry.delegate = self
        // voipRegistry.desiredPushTypes = Set([PKPushType.voIP])
        voipRegistry.desiredPushTypes = [.voIP]

        let appDelegate = UIApplication.shared.delegate
        guard let controller = appDelegate?.window??.rootViewController as? FlutterViewController else {
            fatalError("rootViewController is not type FlutterViewController")
        }
        let registrar = controller.registrar(forPlugin: "twilio_voice")
        if let unwrappedRegistrar = registrar {
            let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: unwrappedRegistrar.messenger())
            eventChannel.setStreamHandler(self)
        }

        NotificationCenter.default.addObserver(
        self,
        selector: #selector(appWillTerminate),
        name: UIApplication.willTerminateNotification,
        object: nil
       
    )
         TwilioVoiceSDK.audioDevice = self.audioDevice

    }
    
    
    deinit {
        // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
        callKitProvider.invalidate()
        NotificationCenter.default.removeObserver(self)

    }

    // ────────────────────────────────────────────────────────────────────────────
    // MARK: — App-Lifecycle Hang-Up Handlers
    // ────────────────────────────────────────────────────────────────────────────

    @objc private func appWillTerminate() {
        guard let call = self.call else { return }
        sendPhoneCallEvents(description: "LOG|App terminating – hanging up call", isError: false)
        performEndCallAction(uuid: call.uuid!)
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
        
        let arguments:Dictionary<String, AnyObject> = flutterCall.arguments as! Dictionary<String, AnyObject>;
        
        if flutterCall.method == "tokens" {
           guard let token = arguments["accessToken"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing accessToken", details: nil))
                return
            }
            self.accessToken = token;
            guard let deviceToken = deviceToken else {
                self.sendPhoneCallEvents(description: "LOG|Device token is nil. Cannot register for VoIP push notifications.", isError: true)
                return
            }
            if let token = accessToken {
                self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { (error) in
                    if let error = error {
                        self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    }
                    else {
                        self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                    }
                }
            }
            //  guard let tokenString = arguments["accessToken"] as? String else {
            //     self.sendPhoneCallEvents(description: "LOG|accessToken is missing or not a String", isError: true)
            //     return
            // }
            //  self.accessToken = tokenString
            //   if let existingToken = self.deviceToken {
            //     self.sendPhoneCallEvents(description: "LOG|registering with Twilio (cached deviceToken)", isError: false)
            //     TwilioVoiceSDK.register(accessToken: tokenString, deviceToken: existingToken) { error in
            //         if let error = error {
            //             self.sendPhoneCallEvents(description: "LOG|Failed to register Twilio (cached): \(error.localizedDescription)", isError: false)
            //         } else {
            //             self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP pushes (cached).", isError: false)
            //         }
            //     }
            //     return
            // }
            // self.sendPhoneCallEvents(description: "LOG|deviceToken is nil – asking APNs for new VoIP push token…", isError: false)
            voipRegistry.desiredPushTypes = [.voIP]
            // guard let token = arguments["accessToken"] as? String else {return}
            // self.accessToken = token
            // if let deviceToken = deviceToken, let token = accessToken {
            //     self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
            //     TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { (error) in
            //         if let error = error {
            //             self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
            //         }
            //         else {
            //             self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
            //         }
            //     }
            // }
        } else if flutterCall.method == "makeCall" {
            guard let callTo = arguments["To"] as? String else {return}
            guard let callFrom = arguments["From"] as? String else {return}
            self.callArgs = arguments
            self.callOutgoing = true
            if let accessToken = arguments["accessToken"] as? String{
                self.accessToken = accessToken
            }
            self.callTo = callTo
            self.identity = callFrom
            makeCall(to: callTo)
        }
        else if flutterCall.method == "toggleMute"
        {
            guard let muted = arguments["muted"] as? Bool else {return}
            if (self.call != nil) {

                self.call!.isMuted = muted
                guard let eventSink = eventSink else {
                    return
                }
                eventSink(muted ? "Mute" : "Unmute")
            } else {
                let ferror: FlutterError = FlutterError(code: "MUTE_ERROR", message: "No call to be muted", details: nil)
                _result!(ferror)
            }
        }
        else if flutterCall.method == "isMuted"
        {
            if(self.call != nil) {
                result(self.call!.isMuted);
            } else {
                result(false);
            }
        }
        else if flutterCall.method == "toggleSpeaker"
        {
            guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else {return}
            toggleAudioRoute(toSpeaker: speakerIsOn)
            guard let eventSink = eventSink else {
                return
            }
            eventSink(speakerIsOn ? "Speaker On" : "Speaker Off")
        }
        else if flutterCall.method == "isOnSpeaker"
        {
            let isOnSpeaker: Bool = isSpeakerOn();
            result(isOnSpeaker);
        }
        else if flutterCall.method == "toggleBluetooth"
        {
            guard let bluetoothOn = arguments["bluetoothOn"] as? Bool else {return}
            // TODO: toggle bluetooth
            // toggleAudioRoute(toSpeaker: speakerIsOn)
            guard let eventSink = eventSink else {
                return
            }
            eventSink(bluetoothOn ? "Bluetooth On" : "Bluetooth Off")
        }
        else if flutterCall.method == "isBluetoothOn"
        {
            let isBluetoothOn: Bool = isBluetoothOn();
            result(isBluetoothOn);
        }
        else if flutterCall.method == "call-sid"
        {
            result(self.call == nil ? nil : self.call!.sid);
            return;
        }
        else if flutterCall.method == "isOnCall"
        {
            result(self.call != nil);
            return;
        }
        else if flutterCall.method == "sendDigits"
        {
            guard let digits = arguments["digits"] as? String else {return}
            if (self.call != nil) {
                self.call!.sendDigits(digits);
            }
        }
        /* else if flutterCall.method == "receiveCalls"
         {
         guard let clientIdentity = arguments["clientIdentifier"] as? String else {return}
         self.identity = clientIdentity;
         } */
        else if flutterCall.method == "holdCall" {
            guard let shouldHold = arguments["shouldHold"] as? Bool else {return}
            
            if (self.call != nil) {
                let hold = self.call!.isOnHold
                if(shouldHold && !hold) {
                    self.call!.isOnHold = true
                    guard let eventSink = eventSink else {
                        return
                    }
                    eventSink("Hold")
                } else if(!shouldHold && hold) {
                    self.call!.isOnHold = false
                    guard let eventSink = eventSink else {
                        return
                    }
                    eventSink("Unhold")
                }
            }
        }
        else if flutterCall.method == "isHolding" {
            // guard call not nil
            guard let call = self.call else {
                return;
            }
            
            // toggle state current state
            let isOnHold = call.isOnHold;
            call.isOnHold = !isOnHold;
            
            // guard event sink not nil & post update
            guard let eventSink = eventSink else {
                return
            }
            eventSink(!isOnHold ? "Hold" : "Unhold")
        }
        else if flutterCall.method == "answer" {
           if(self.callInvite != nil) {
                let ci = self.callInvite!
                self.sendPhoneCallEvents(description: "LOG|answer method invoked", isError: false)
                self.answerCall(callInvite: ci)
            } else {
                let ferror: FlutterError = FlutterError(code: "ANSWER_ERROR", message: "No call invite to answer", details: nil)
                _result!(ferror)
            }
        }
        else if flutterCall.method == "unregister" {
            // guard let deviceToken = deviceToken else {
            //     return
            // }
            // if let token = arguments["accessToken"] as? String{
            //     self.unregisterTokens(token: token, deviceToken: deviceToken)
            // }else if let token = accessToken{
            //     self.unregisterTokens(token: token, deviceToken: deviceToken)
            // }
            if let cachedToken = self.deviceToken {
                if let token = arguments["accessToken"] as? String {
                    self.unregisterTokens(token: token, deviceToken: cachedToken)
                } else if let token = self.accessToken {
                    self.unregisterTokens(token: token, deviceToken: cachedToken)
                }
            }
            
        }else if flutterCall.method == "hangUp"{
           
            // Hang up on-going/active call
        //     if (self.call != nil) {
        //         self.sendPhoneCallEvents(description: "LOG|hangUp method invoked", isError: false)
        //         self.userInitiatedDisconnect = true
        //         performEndCallAction(uuid: self.call!.uuid!)
        //         //self.toggleUIState(isEnabled: false, showCallControl: false)
        //    }
        if let currentCall = self.call {
        // 1) Tell Twilio’s Call object to disconnect (this will trigger callDidDisconnect(_:))
        self.sendPhoneCallEvents(description: "LOG|hangUp method invoked", isError: false)
        self.userInitiatedDisconnect = true
        currentCall.disconnect()

        // 2) Immediately end the CallKit call so the native in-call UI goes away at once
        performEndCallAction(uuid: currentCall.uuid!)
        //Hang up on-going/active call
            if (self.call != nil) {
                self.sendPhoneCallEvents(description: "LOG|hangUp method invoked", isError: false)
                self.userInitiatedDisconnect = true
                performEndCallAction(uuid: self.call!.uuid!)
                //self.toggleUIState(isEnabled: false, showCallControl: false)
            } else if(self.callInvite != nil) {
                performEndCallAction(uuid: self.callInvite!.uuid)
            }
   }
        }else if flutterCall.method == "registerClient"{
            guard let clientId = arguments["id"] as? String, let clientName =  arguments["name"] as? String else {return}
            if clients[clientId] == nil || clients[clientId] != clientName{
                clients[clientId] = clientName
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
            
        }else if flutterCall.method == "unregisterClient"{
            guard let clientId = arguments["id"] as? String else {return}
            clients.removeValue(forKey: clientId)
            UserDefaults.standard.set(clients, forKey: kClientList)
            
        }else if flutterCall.method == "defaultCaller"{
            guard let caller = arguments["defaultCaller"] as? String else {return}
            defaultCaller = caller
            if(clients["defaultCaller"] == nil || clients["defaultCaller"] != defaultCaller){
                clients["defaultCaller"] = defaultCaller
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
        }else if flutterCall.method == "hasMicPermission" {
            let permission = AVAudioSession.sharedInstance().recordPermission
            result(permission == .granted)
            return
        }else if flutterCall.method == "requestMicPermission"{
            switch(AVAudioSession.sharedInstance().recordPermission){
            case .granted:
                result(true)
            case .denied:
                result(false)
            case .undetermined:
                AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
                    result(granted)
                })
            @unknown default:
                result(false)
            }
            return
        } else if flutterCall.method == "hasBluetoothPermission" {
            result(true)
            return
        }else if flutterCall.method == "requestBluetoothPermission"{
            result(true)
            return
        } else if flutterCall.method == "showNotifications" {
            guard let show = arguments["show"] as? Bool else{return}
            let prefsShow = UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true
            if show != prefsShow{
                UserDefaults.standard.setValue(show, forKey: "show-notifications")
            }
            result(true)
            return
        } else if flutterCall.method == "updateCallKitIcon" {
            let newIcon = arguments["icon"] as? String ?? defaultCallKitIcon
            
            // update icon & persist
            result(updateCallKitIcon(icon: newIcon))
            return
        }else if flutterCall.method == "connectToConference" {
   
     guard let conferenceName = arguments["conferenceName"] as? String else {
                 result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing conferenceName", details: nil))
                 return
             }
             guard let displayName = arguments["displayName"] as? String else {
                 result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing displayName", details: nil))
                 return
             }
             let uuid = UUID()
             self.connectToConference(uuid: uuid, conferenceName: conferenceName,displayName:displayName) { success in
                 result(success)}
   
        } else  if flutterCall.method == "updateDisplayName" {
        guard let args = flutterCall.arguments as? [String:Any],
              let newName = args["name"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing name", details: nil))
            return
        }
        updateCurrentCallDisplayName(to: newName)
        result(true)
        return
    } else if flutterCall.method == "getCustomParams" {
            result(getCustomParams())
            return
        }
        else if flutterCall.method == "clearCustomParams" {
            clearCustomParams()
            result(true)
            return
        }
      else  if flutterCall.method == "setCallVolume" {
        guard
    let args = flutterCall.arguments as? [String:Any],
    let level = args["level"] as? Float
  else {
    result(FlutterError(code: "INVALID_ARGS", message: "Missing level", details: nil))
    return
  }
  Self.setSystemVolume(level)
  result(nil)
  return
      }
        result(true)
    }
    

    static func setSystemVolume(_ level: Float) {
    DispatchQueue.main.async {
      for sub in volumeView.subviews {
        if let slider = sub as? UISlider {
          slider.value = level
          break
        }
      }
    }
  }

    // MARK: — Ringback Tone Playback

    private func playRingbackTone() {
    //  // don’t start twice
    // guard ringtonePlayer == nil else { return }

    // // 1) Get the bundle for *this* plugin pod
    // let bundle = Bundle(for: SwiftTwilioVoicePlugin.self)

    // // 2) Look for the exact resource name you declared in your Podspec
    // guard let url = bundle.url(
    //     forResource: "phone-outgoing-call-72202",
    //     withExtension: "mp3"
    // ) else {
    //     NSLog("⚠️ ringback file not found in plugin bundle")
    //     return
    // }

    // do {
    //     // 3) Configure & activate the session so playback actually happens
    //     let session = AVAudioSession.sharedInstance()
    //     try session.setCategory(.playAndRecord,
    //                             mode: .default,
    //                             options: [.duckOthers,.mixWithOthers,.allowBluetooth,.defaultToSpeaker])
    //     // try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers])
    //     // try session.overrideOutputAudioPort(.speaker)                      
    //     try session.setActive(true)

    //     // 4) Create & start the player
    //     ringtonePlayer = try AVAudioPlayer(contentsOf: url)
    //      ringtonePlayer?.volume = 1.0
    //     ringtonePlayer?.numberOfLoops = -1
    //     ringtonePlayer?.prepareToPlay()
    //     ringtonePlayer?.play()
    // } catch {
    //     NSLog("⚠️ failed to start ringback: \(error)")
    //     ringtonePlayer = nil
    // }
    guard ringtonePlayer == nil else { return }
    let ringURL: URL? = {
      if let main = Bundle.main.url(forResource: "phone-outgoing-call-72202", withExtension: "mp3") {
        return main
      }
     
      guard
        let bundleRoot = Bundle(for: SwiftTwilioVoicePlugin.self)
                              .url(forResource: "TwilioVoicePluginResources", withExtension: "bundle"),
        let resBundle = Bundle(url: bundleRoot)
      else { return nil }
      return resBundle.url(forResource: "phone-outgoing-call-72202", withExtension: "mp3")
    }()

    guard let url = ringURL else {
      NSLog("⚠️ ringback file not found")
      return
    }

    do {
   
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.duckOthers, .mixWithOthers, .allowBluetooth]
      )
   
      try session.overrideOutputAudioPort(.speaker)
      try session.setActive(true)

    
      ringtonePlayer = try AVAudioPlayer(contentsOf: url)
      ringtonePlayer?.volume = 1.0
      ringtonePlayer?.numberOfLoops = -1
      ringtonePlayer?.prepareToPlay()
      ringtonePlayer?.play()
    } catch {
      NSLog("⚠️ failed to start ringback: \(error)")
      ringtonePlayer = nil
    }
    }

    private func stopRingbackTone() {
        guard let player = ringtonePlayer else { return }
    if player.isPlaying { player.stop() }
    ringtonePlayer = nil

    // deactivate if you want
    // try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }

    func updateCurrentCallDisplayName(to newName: String) {
    guard let activeCall = self.call else {
        NSLog("No active call to update")
        return
    }
    // Unwrap the optional UUID
    guard let uuid = activeCall.uuid else {
        NSLog("Active call has no UUID")
        return
    }

    // Build a CXCallUpdate
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: activeCall.to ?? activeCall.from ?? "")
    update.localizedCallerName = newName
    update.supportsDTMF = true
    update.supportsHolding = true
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.hasVideo = false

    // Tell CallKit to apply it
    callKitProvider.reportCall(with: uuid, updated: update)
}



    /// Updates the CallkitProvider configuration with a new icon, and saves this change to future use.
    /// - Parameter icon: icon path / name
    /// - Returns: true if succesful
    func updateCallKitIcon(icon: String) -> Bool {
        if let newIcon = UIImage(named: icon) {
            let configuration = callKitProvider.configuration;
            
            // set new callkit icon
            configuration.iconTemplateImageData = newIcon.pngData()
            callKitProvider.configuration = configuration
         
            // save new icon to persist across sessions
            UserDefaults.standard.set(icon, forKey: defaultCallKitIcon)
            
            return true;
        }
        
        return false;
    }

    func answerCall(callInvite: CallInvite) {
        let answerCallAction = CXAnswerCallAction(call: callInvite.uuid)
        let transaction = CXTransaction(action: answerCallAction)
        
        callKitCallController.request(transaction)  { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|AnswerCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                return
            }
        }
    }
    
    func makeCall(to: String)
    {
        // Cancel the previous call before making another one.
        // if (self.call != nil) {
        //     self.userInitiatedDisconnect = true
        //     performEndCallAction(uuid: self.call!.uuid!)            
        // } else {
        //     let uuid = UUID()
            
        //     self.checkRecordPermission { (permissionGranted) in
        //         if (!permissionGranted) {
        //             let alertController: UIAlertController = UIAlertController(title: String(format:  NSLocalizedString("mic_permission_title", comment: "") , SwiftTwilioVoicePlugin.appName),
        //                                                                        message: NSLocalizedString( "mic_permission_subtitle", comment: ""),
        //                                                                        preferredStyle: .alert)
                    
        //             let continueWithMic: UIAlertAction = UIAlertAction(title: NSLocalizedString("btn_continue_no_mic", comment: ""),
        //                                                                style: .default,
        //                                                                handler: { (action) in
        //                                                                 self.performStartCallAction(uuid: uuid, handle: to)
        //                                                                })
        //             alertController.addAction(continueWithMic)
                    
        //             let goToSettings: UIAlertAction = UIAlertAction(title:NSLocalizedString("btn_settings", comment: ""),
        //                                                             style: .default,
        //                                                             handler: { (action) in
        //                                                                 UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
        //                                                                                           options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: false],
        //                                                                                           completionHandler: nil)
        //                                                             })
        //             alertController.addAction(goToSettings)
                    
        //             let cancel: UIAlertAction = UIAlertAction(title: NSLocalizedString("btn_cancel", comment: ""),
        //                                                       style: .cancel,
        //                                                       handler: { (action) in
        //                                                         //self.toggleUIState(isEnabled: true, showCallControl: false)
        //                                                         //self.stopSpin()
        //                                                       })
        //             alertController.addAction(cancel)
        //             // guard let currentViewController = UIApplication.shared.keyWindow?.topMostViewController() else {
        //             //     return
        //             // }
        //             // currentViewController.present(alertController, animated: true, completion: nil)
        //             guard let currentVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.topMostViewController() else { return }
        //             currentVC.present(alertController, animated: true, completion: nil)
                    
        //         } else {
        //             self.performStartCallAction(uuid: uuid, handle: to)
        //         }
        //     }
        // }
        if let current = self.call, let oldUUID = current.uuid {
        self.userInitiatedDisconnect = true
        current.disconnect()
        performEndCallAction(uuid: oldUUID)
        self.call = nil
    }

    var params = self.callArgs as [String: Any]
    if params["To"] == nil { params["To"] = to }
    if params["From"] == nil { params["From"] = self.identity }
    self.callArgs = params.reduce(into: [String: AnyObject]()) { $0[$1.key] = $1.value as AnyObject }

    // 3) Mark as outbound so ringback/logging behave correctly.
    self.callOutgoing = true

    // 4) Always start via CallKit; Twilio connect happens in provider(_:perform:).
    let uuid = UUID()
    self.checkRecordPermission { granted in
        guard granted else {
            let alert = UIAlertController(
                title: String(format: NSLocalizedString("mic_permission_title", comment: ""), SwiftTwilioVoicePlugin.appName),
                message: NSLocalizedString("mic_permission_subtitle", comment: ""),
                preferredStyle: .alert
            )
            let continueWithMic = UIAlertAction(title: NSLocalizedString("btn_continue_no_mic", comment: ""), style: .default) { _ in
                self.performStartCallAction(uuid: uuid, handle: to)
            }
            let goToSettings = UIAlertAction(title: NSLocalizedString("btn_settings", comment: ""), style: .default) { _ in
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [.universalLinksOnly: false], completionHandler: nil)
            }
            let cancel = UIAlertAction(title: NSLocalizedString("btn_cancel", comment: ""), style: .cancel)

            alert.addAction(continueWithMic)
            alert.addAction(goToSettings)
            alert.addAction(cancel)

            if let currentVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.topMostViewController() {
                currentVC.present(alert, animated: true, completion: nil)
            }
            return
        }

        self.performStartCallAction(uuid: uuid, handle: to)
    }
    }
    
    func checkRecordPermission(completion: @escaping (_ permissionGranted: Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            // Record permission already granted.
            completion(true)
            break
        case .denied:
            // Record permission denied.
            completion(false)
            break
        case .undetermined:
            // Requesting record permission.
            // Optional: pop up app dialog to let the users know if they want to request.
            AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
                completion(granted)
            })
            break
        default:
            completion(false)
            break
        }
    }
    
    
    // MARK: PKPushRegistryDelegate
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
       self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType:", isError: false)
        
        if (type != .voIP) {
            return
        }
        
        guard registrationRequired() || deviceToken != credentials.token else {
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials device token unchanged, no update needed.", isError: true)
            return
        }

        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType: device token updated", isError: false)
        let deviceToken = credentials.token
        
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
        if let token = accessToken {
            TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { (error) in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    self.sendPhoneCallEvents(description: "DEVICETOKEN|\(String(decoding: deviceToken, as: UTF8.self))", isError: false)
                }
                else {
                    self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                }
            }
        }
        self.deviceToken = deviceToken
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
      
        // self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType:", isError: false)
        
        //  guard type == .voIP else { return }

        // let newToken = credentials.token
        // let previouslySaved = self.deviceToken    

        // if registrationRequired() || previouslySaved != newToken {
        //     self.sendPhoneCallEvents(description: "LOG|PushKit gave us a new token; registering with Twilio…", isError: false)
        //     if let tokenStr = self.accessToken {
        //         TwilioVoiceSDK.register(accessToken: tokenStr, deviceToken: newToken) { error in
        //             if let error = error {
        //                 self.sendPhoneCallEvents(description: "LOG|TwilioVoiceSDK.register error: \(error.localizedDescription)", isError: false)
        //             } else {
        //                 self.sendPhoneCallEvents(description: "LOG|Registered for VoIP pushes (new token).", isError: false)
        //             }
        //         }
        //     } else {
        //         self.sendPhoneCallEvents(description: "LOG|Have deviceToken but no accessToken yet.", isError: false)
        //     }
        // }
        
        // // Cache new token and timestamp
        // self.deviceToken = newToken
        // UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)

    }
    
    /**
      * The TTL of a registration is 1 year. The TTL for registration for this device/identity pair is reset to
      * 1 year whenever a new registration occurs or a push notification is sent to this device/identity pair.
      * This method checks if binding exists in UserDefaults, and if half of TTL has been passed then the method
      * will return true, else false.
      */
     func registrationRequired() -> Bool {
        //  guard
        //      let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate)
        //  else { return true }

        //  let date = Date()
        //  var components = DateComponents()
        //  components.setValue(kRegistrationTTLInDays/2, for: .day)
        //  let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated as! Date)!

        //  if expirationDate.compare(date) == ComparisonResult.orderedDescending {
        //      return false
        //  }
        //  return true;
          guard let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate) else {
             self.sendPhoneCallEvents(description: "LOG|Registration required: true, last binding date not found", isError: false)
             return true
         }

         let date = Date()
         var components = DateComponents()
         components.setValue(kRegistrationTTLInDays/2, for: .day)
         let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated as! Date)!

         if expirationDate.compare(date) == ComparisonResult.orderedDescending {
             self.sendPhoneCallEvents(description: "LOG|Registration required: false, half of TTL not passed", isError: false)
             return false
         }
         return true;
     }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didInvalidatePushTokenForType:", isError: false)
        
        if (type != .voIP) {
            return
        }
        
        self.unregister()
    }
    
    func unregister() {
        
        guard let deviceToken = deviceToken, let token = accessToken else {
            self.sendPhoneCallEvents(description: "LOG|Missing required parameters to unregister", isError: true)
            return
        }
        
        self.unregisterTokens(token: token, deviceToken: deviceToken)
    }
    
    func unregisterTokens(token: String, deviceToken: Data) {
       
         TwilioVoiceSDK.unregister(accessToken: token, deviceToken: deviceToken) { (error) in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|An error occurred while unregistering: \(error.localizedDescription)", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Successfully unregistered from VoIP push notifications.", isError: false)
            }
        }
        self.deviceToken = nil
        
        // Force PushKit to drop & fetch a fresh token
        voipRegistry.desiredPushTypes = []       // ← CHANGED
        voipRegistry.desiredPushTypes = [.voIP]  // ← CHANGED
    }
    
    /**
     * Try using the `pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:` method if
     * your application is targeting iOS 11. According to the docs, this delegate method is deprecated by Apple.
     */
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:", isError: false)
        lastVoipPushReceivedAt = Date()
        lastVoipPushSummary = summarizeVoipPayload(payload.dictionaryPayload)
        
        if (type == PKPushType.voIP) {
            TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
    }
    
    /**
     * This delegate method is available on iOS 11 and above. Call the completion handler once the
     * notification payload is passed to the `TwilioVoice.handleNotification()` method.
     */
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:completion:", isError: false)
        // Save for later when the notification is properly handled.
//        self.incomingPushCompletionCallback = completion
        lastVoipPushReceivedAt = Date()
        lastVoipPushSummary = summarizeVoipPayload(payload.dictionaryPayload)
        
        if (type == PKPushType.voIP) {
            TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
        
        if let version = Float(UIDevice.current.systemVersion), version < 13.0 {
            // Save for later when the notification is properly handled.
            self.incomingPushCompletionCallback = completion
        } else {
            /**
             * The Voice SDK processes the call notification and returns the call invite synchronously. Report the incoming call to
             * CallKit and fulfill the completion before exiting this callback method.
             */
            completion()
        }
    }

    // MARK: CXCallObserverDelegate
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let uuid = call.uuid

        if call.hasEnded {
            activeCalls.removeValue(forKey: uuid) // Remove ended calls
        } else {
            activeCalls[uuid] = call // Add or update call
        }
    }
    
    // Check if a call with a given UUID exists
    func isCallActive(uuid: UUID) -> Bool {
        return activeCalls[uuid] != nil
    }
    
    func incomingPushHandled() {
        if let completion = self.incomingPushCompletionCallback {
            self.incomingPushCompletionCallback = nil
            completion()
        }
    }
    
    // MARK: TVONotificaitonDelegate
    public func callInviteReceived(callInvite: CallInvite) {

         if let custom = callInvite.customParameters {
            saveCustomParams(custom)
        }
        // self.sendPhoneCallEvents(description: "LOG|callInviteReceived:", isError: false)
        
        // /**
        //  * The TTL of a registration is 1 year. The TTL for registration for this device/identity
        //  * pair is reset to 1 year whenever a new registration occurs or a push notification is
        //  * sent to this device/identity pair.
        //  */
        // UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        // var from:String = callInvite.from ?? defaultCaller
        // from = from.replacingOccurrences(of: "client:", with: "")
        
        // self.sendPhoneCallEvents(description: "Ringing|\(from)|\(callInvite.to)|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        // reportIncomingCall(from: from, uuid: callInvite.uuid)
        // self.callInvite = callInvite
        self.sendPhoneCallEvents(description: "LOG|callInviteReceived:", isError: false)
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        // let from: String? = callInvite.customParameters!["firstname"] ?? ""
        // let fromx: String? = callInvite.customParameters!["lastname"] ?? ""
        // var fromx1: String = callInvite.from ?? ""
        let first: String = (callInvite.customParameters?["firstname"] as? String ?? "")
        let last:  String = (callInvite.customParameters?["lastname"]  as? String ?? "")
        var fromx1: String = callInvite.from ?? ""
        fromx1 = fromx1.replacingOccurrences(of: "client:", with: "")
        lastCallInviteReceivedAt = Date()
        lastCallInviteFrom = fromx1
        lastIncomingCallUUID = callInvite.uuid
        logIncomingCallDiagnostics(trigger: "incoming_call_invite_received", callUUID: callInvite.uuid, callInvite: callInvite)
         self.sendPhoneCallEvents(description: "Ringing|\(first)|\(callInvite.to)|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        // self.sendPhoneCallEvents(description: "Ringing|\(from)|\(callInvite.to)|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        // reportIncomingCall(from: from!, fromx: fromx!, fromx1: fromx1, uuid: callInvite.uuid)
        reportIncomingCall(from: first, fromx: last, fromx1: fromx1, uuid: callInvite.uuid)
        self.callInvite = callInvite

    }
    
    func formatCustomParams(params: [String:Any]?)->String{
        guard let customParameters = params else{return ""}
        do{
            let jsonData = try JSONSerialization.data(withJSONObject: customParameters)
            if let jsonStr = String(data: jsonData, encoding: .utf8){
                return "|\(jsonStr )"
            }
        }catch{
            print("unable to send custom parameters")
        }
        return ""
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        //  clearCustomParams()
        // self.sendPhoneCallEvents(description: "Missed Call", isError: false)
        // self.sendPhoneCallEvents(description: "LOG|cancelledCallInviteCanceled:", isError: false)
        // self.showMissedCallNotification(from: cancelledCallInvite.from, to: cancelledCallInvite.to)
        // if (self.callInvite == nil) {
        //     self.sendPhoneCallEvents(description: "LOG|No pending call invite", isError: false)
        //     return
        // }
        
        // if let ci = self.callInvite {
        //     performEndCallAction(uuid: ci.uuid)
        // }
        clearCustomParams()
        var extra: [String: Any] = [:]
        if let cancelFrom = cancelledCallInvite.from, !cancelFrom.isEmpty {
            extra["cancelFrom"] = cancelFrom
        }
        if let to = cancelledCallInvite.to { extra["cancelTo"] = to }
        logIncomingCallDiagnostics(trigger: "incoming_call_invite_cancelled",
                                   reason: error.localizedDescription,
                                   callUUID: self.callInvite?.uuid,
                                   callInvite: self.callInvite,
                                   extra: extra)
        sendPhoneCallEvents(description: "Missed Call", isError: false)
        sendPhoneCallEvents(description: "LOG|cancelledCallInviteCanceled:", isError: false)
        showMissedCallNotification(from: cancelledCallInvite.from, to: cancelledCallInvite.to)

        guard let ci = self.callInvite else {
            sendPhoneCallEvents(description: "LOG|No pending call invite", isError: false)
            return
        }

        // Mark that we’re rejecting, so callDidDisconnect won’t fire “Call Ended”
        isRejectingCallInvite = true
        performEndCallAction(uuid: ci.uuid)
    }
    
    func showMissedCallNotification(from:String?, to:String?){
        guard UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true else{return}
        let notificationCenter = UNUserNotificationCenter.current()

       
        notificationCenter.getNotificationSettings { (settings) in
          if settings.authorizationStatus == .authorized {
            let content = UNMutableNotificationContent()
            var userName:String?
            if var from = from{
                from = from.replacingOccurrences(of: "client:", with: "")
                content.userInfo = ["type":"twilio-missed-call", "From":from]
                if let to = to{
                    content.userInfo["To"] = to
                }
                userName = self.clients[from]
            }
            
            let title = userName ?? self.clients["defaultCaller"] ?? self.defaultCaller
            content.title = title
            content.body = NSLocalizedString("notification_missed_call_body", comment: "")

            // content.title = String(format:  NSLocalizedString("notification_missed_call", comment: ""),title)

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: trigger)
            
                notificationCenter.add(request) { (error) in
                    if let error = error {
                        print("Notification Error: ", error)
                    }
                }
            
          }
        }
    }
    
    // MARK: TVOCallDelegate
    public func callDidStartRinging(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = (call.from ?? self.identity)
        let to = (call.to ?? self.callTo)
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(to)|\(direction)", isError: false)
        
       saveCustomParams(callArgs as [String:Any])
       if self.callOutgoing {
    playRingbackTone()
   }
        //self.placeCallButton.setTitle("Ringing", for: .normal)
    }
    
    public func callDidConnect(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = (call.from ?? self.identity)
        let to = (call.to ?? self.callTo)
        self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)

      
        audioDevice.isEnabled = true
        callKitCompletionCallback?(true)
     stopRingbackTone()
        if let callKitCompletionCallback = callKitCompletionCallback {
            callKitCompletionCallback(true)
        }
         audioDevice.isEnabled = true
         stopRingbackTone()
          callKitCompletionCallback?(true)

         saveCustomParams(callArgs as [String:Any])
        
        //toggleAudioRoute(toSpeaker: false)
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
        
      stopRingbackTone()
        
        if(error.localizedDescription.contains("Access Token expired")){
            self.sendPhoneCallEvents(description: "DEVICETOKEN", isError: false)
        }
        if let completion = self.callKitCompletionCallback {
            completion(false)
        }
        
        
        callKitProvider.reportCall(with: call.uuid!, endedAt: Date(), reason: CXCallEndedReason.failed)
        callDisconnected()

    
    }
    
    // @objc(callDidDisconnect:error:)
    public func callDidDisconnect(call: Call, error: Error?) {
       
     clearCustomParams()
        stopRingbackTone()

   
     let reason: CXCallEndedReason = (error == nil)
      ? .remoteEnded    
      : .failed    
    // self.userInitiatedDisconnect
    //   ? .remoteEnded
    //   : .failed
    callKitProvider.reportCall(
      with: call.uuid!,
      endedAt: Date(),
      reason: reason
    )
    sendPhoneCallEvents(description: "Call Ended", isError: false)

    
    if let err = error {
      sendPhoneCallEvents(description: "Call Ended: \(err.localizedDescription)", isError: true)
    }
    isRejectingCallInvite = false
    userInitiatedDisconnect = false
    self.call               = nil
    self.callInvite         = nil

  
    }
    
    func callDisconnected() {
           stopRingbackTone()
        self.sendPhoneCallEvents(description: "LOG|Call Disconnected", isError: false)
        if (self.call != nil) {
            
            self.sendPhoneCallEvents(description: "LOG|Setting call to nil", isError: false)
            self.call = nil
        }
        if (self.callInvite != nil) {
            self.callInvite = nil
        }
        
        self.callOutgoing = false
        self.userInitiatedDisconnect = false
        self.lastIncomingCallUUID = nil
        self.lastCallInviteReceivedAt = nil
        self.lastCallInviteFrom = nil
        
    }
    
    func isSpeakerOn() -> Bool {
        // Source: https://stackoverflow.com/a/51759708/4628115
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        for output in currentRoute.outputs {
            switch output.portType {
                case AVAudioSession.Port.builtInSpeaker:
                    return true;
                default:
                    return false;
            }
        }
        return false;
    }

    // TODO
    func isBluetoothOn() -> Bool {
        return false;
    }

    // MARK: AVAudioSession
    func toggleAudioRoute(toSpeaker: Bool) {
        // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver. Use port override to switch the route.
        audioDevice.block = {
            DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
            do {
                if (toSpeaker) {
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
        
        self.performVoiceCall(uuid: action.callUUID, client: "") { (success) in
            if (success) {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() successful", isError: false)
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            } else {
                self.sendPhoneCallEvents(description: "LOG|provider:performVoiceCall() failed", isError: false)
                self.callKitProvider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                self.callDisconnected()
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performAnswerCallAction:", isError: false)
        
        
        self.performAnswerVoiceCall(uuid: action.callUUID) { (success) in
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
        
        
        if (self.callInvite != nil) {
            self.isRejectingCallInvite = true
            clearCustomParams()
            self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: rejecting call", isError: false)
            self.callInvite?.reject()
            self.callInvite = nil
        }else if let call = self.call {
            self.userInitiatedDisconnect = true
            clearCustomParams()
            self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: disconnecting call", isError: false)
            call.disconnect()
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetHeldAction:", isError: false)
        if let call = self.call {
            call.isOnHold = action.isOnHold
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetMutedAction:", isError: false)
        
        if let call = self.call {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    // MARK: Call Kit Actions
    func performStartCallAction(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        let transaction = CXTransaction(action: startCallAction)
        
        callKitCallController.request(transaction)  { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                return
            }
            
            self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request successful", isError: false)


            // Determine the custom display name using your extra parameters.
            // Here we check for "from_firstname" and "from_lastname" in callArgs.
            // var displayName = handle  // fallback to the handle if custom values are not provided
            // if let fromFirstName = self.callArgs["to_firstname"] as? String,
            // let fromLastName = self.callArgs["to_lastname"] as? String,
            // (!fromFirstName.isEmpty || !fromLastName.isEmpty) {
            //     displayName = "\(fromFirstName) \(fromLastName)".trimmingCharacters(in: .whitespaces)
            // }

            var displayName: String = handle
            let fn = (self.callArgs["to_firstname"] as? String ?? "")
            let ln = (self.callArgs["to_lastname"]  as? String ?? "")
            let combined = "\(fn) \(ln)".trimmingCharacters(in: .whitespaces)
            if !combined.isEmpty { displayName = combined }

            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.localizedCallerName = displayName.isEmpty ? (self.clients[handle] ?? self.clients["defaultCaller"] ?? self.defaultCaller) : displayName

            // callUpdate.localizedCallerName = displayName ?? self.clients[handle] ?? self.clients["defaultCaller"] ?? self.defaultCaller
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
            self.lastCallKitReportTimestamp = Date()
            self.lastIncomingCallUUID = uuid
            if let error = error {
                self.lastCallKitReportError = error.localizedDescription
                self.sendPhoneCallEvents(description: "LOG|Failed to report incoming call successfully: \(error.localizedDescription).", isError: false)
                self.logIncomingCallDiagnostics(trigger: "callkit_report_failed",
                                                reason: error.localizedDescription,
                                                callUUID: uuid,
                                                callInvite: self.callInvite)
            } else {
                self.lastCallKitReportError = nil
                self.sendPhoneCallEvents(description: "LOG|Incoming call successfully reported.", isError: false)
            }
        }
    }
    
    func performEndCallAction(uuid: UUID) {
        
        // self.sendPhoneCallEvents(description: "LOG|performEndCallAction method invoked", isError: false)

        // guard isCallActive(uuid: uuid) else {
        //     print("Call not found or already ended. Skipping end request.")
        //     self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        //     return
        // }
        
        // let endCallAction = CXEndCallAction(call: uuid)
        // let transaction = CXTransaction(action: endCallAction)
        
        // callKitCallController.request(transaction) { error in
        //     if let error = error {
        //         self.sendPhoneCallEvents(description: "End Call Failed: \(error.localizedDescription).", isError: true)
        //     } else {
        //         self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        //     }
        // }
        sendPhoneCallEvents(description: "LOG|performEndCallAction method invoked", isError: false)
    let end = CXEndCallAction(call: uuid)
    let tx = CXTransaction(action: end)
    callKitCallController.request(tx) { err in
        if let err = err {
            self.sendPhoneCallEvents(description: "End Call Failed: \(err.localizedDescription).", isError: true)
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
        
        let connectOptions: ConnectOptions = ConnectOptions(accessToken: token) { (builder) in
            for (key, value) in self.callArgs {
                if (key != "From") {
                    builder.params[key] = "\(value)"
                }
            }
            builder.uuid = uuid
        }
        let theCall = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
        self.call = theCall
        self.callKitCompletionCallback = completionHandler
    }

    private func startViaCallKit(uuid: UUID,
                             handle: String,
                             params: [String: Any],
                             completion: ((Bool) -> Void)? = nil) {
    // End any existing call
    if let existing = self.call, let existingUUID = existing.uuid {
        self.userInitiatedDisconnect = true
        existing.disconnect()
        performEndCallAction(uuid: existingUUID)
        self.call = nil
    }

    // Stash params; performVoiceCall() will read these and pass to Twilio
    self.callArgs = params.reduce(into: [String: AnyObject]()) { $0[$1.key] = $1.value as AnyObject }
    self.callOutgoing = true
    if let completion = completion { self.callKitCompletionCallback = completion }

    // This triggers provider(_:perform: CXStartCallAction) → performVoiceCall(...)
    performStartCallAction(uuid: uuid, handle: handle)
}
    // Updated connectToConference function without extraOptions:
    func connectToConference(
        uuid: UUID, 
        conferenceName: String, 
        displayName: String, 
        completionHandler: @escaping (Bool) -> Swift.Void) {
        
    //     guard accessToken != nil else {
    //     completionHandler(false)
    //     return
    // }

    //  if let existing = self.call, let existingUUID = existing.uuid {
    //     self.userInitiatedDisconnect = true
    //     existing.disconnect()
    //     performEndCallAction(uuid: existingUUID)
    //     self.call = nil
    // }

    //  self.callArgs = ["conference": conferenceName as AnyObject]

    //  self.callOutgoing = true
    // self.callKitCompletionCallback = completionHandler
    //     self.performStartCallAction(uuid: uuid, handle: displayName)

    startViaCallKit(
        uuid: uuid,
        handle: displayName,
        params: ["conference": conferenceName],
        completion: completionHandler
    )

    //     guard let token = accessToken else {
    //     completionHandler(false)
    //     return
    // }

    // let connectOptions = ConnectOptions(accessToken: token) { builder in
    //     builder.uuid = uuid
    //     builder.params["conference"] = conferenceName
    // }

    // // Only connect once. Assign the returned Call to self.call, so delegate callbacks (callDidConnect, etc.) will fire on that object.
    // let conferenceCall = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
    // self.call = conferenceCall
    // self.callKitCompletionCallback = completionHandler

    // // Enable the audio device immediately (so that the call audio will flow correctly once connected)
    // audioDevice.isEnabled = true
    }
  
    
    func performAnswerVoiceCall(uuid: UUID, completionHandler: @escaping (Bool) -> Swift.Void) {
        if let ci = self.callInvite {
            let acceptOptions: AcceptOptions = AcceptOptions(callInvite: ci) { (builder) in
                builder.uuid = ci.uuid
            }
            self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call", isError: false)
            let theCall = ci.accept(options: acceptOptions, delegate: self)
            self.sendPhoneCallEvents(description: "Answer|\(theCall.from!)|\(theCall.to!)|Incoming\(formatCustomParams(params: ci.customParameters))", isError:false)
            self.call = theCall
            self.callKitCompletionCallback = completionHandler
            self.callInvite = nil
            
            guard #available(iOS 13, *) else {
                self.incomingPushHandled()
                return
            }
        } else {
            self.sendPhoneCallEvents(description: "LOG|No CallInvite matches the UUID", isError: false)
        }
    }
    
    public func onListen(withArguments arguments: Any?,
                         eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(CallDelegate.callDidDisconnect),
            name: NSNotification.Name(rawValue: "PhoneCallEvent"),
            object: nil)
        
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        return nil
    }

    private func logIncomingCallDiagnostics(trigger: String,
                                            reason: String? = nil,
                                            callUUID: UUID? = nil,
                                            callInvite: CallInvite? = nil,
                                            extra: [String: Any] = [:]) {
        var diagnostics: [String: Any] = extra
        diagnostics["trigger"] = trigger

        let isoFormatter = ISO8601DateFormatter()
        diagnostics["timestamp"] = isoFormatter.string(from: Date())

        if let reason = reason, !reason.isEmpty {
            diagnostics["reason"] = reason
        }

        let appState = currentApplicationState()
        diagnostics["appState"] = applicationStateDescription(appState)
        diagnostics["hasVoipToken"] = deviceToken != nil
        diagnostics["registeredForAPNs"] = currentAPNsRegistrationState()

        if let pushReceivedAt = lastVoipPushReceivedAt {
            diagnostics["msSinceVoipPush"] = millisecondsSince(pushReceivedAt)
        }
        if !lastVoipPushSummary.isEmpty {
            diagnostics["voipPushSummary"] = lastVoipPushSummary
        }

        if let inviteReceivedAt = lastCallInviteReceivedAt {
            diagnostics["msSinceCallInvite"] = millisecondsSince(inviteReceivedAt)
        }

        if let invite = callInvite {
            if let inviteFrom = invite.from, !inviteFrom.isEmpty {
                diagnostics["inviteFrom"] = inviteFrom
            }
            let inviteTo = invite.to
            if !inviteTo.isEmpty { diagnostics["inviteTo"] = inviteTo }
            let params = stringifyCustomParameters(invite.customParameters)
            if !params.isEmpty { diagnostics["inviteCustomParams"] = params }
        } else if let cachedFrom = lastCallInviteFrom {
            diagnostics["lastInviteFrom"] = cachedFrom
        }

        let resolvedUUID = callUUID ?? lastIncomingCallUUID
        if let uuid = resolvedUUID {
            diagnostics["callUUID"] = uuid.uuidString
            diagnostics["callKitHasCall"] = isCallActive(uuid: uuid)
        }

        let calls = callObserver.calls
        diagnostics["activeCallCount"] = calls.count
        diagnostics["activeCallStates"] = calls.map { call -> [String: Any] in
            [
                "uuid": call.uuid.uuidString,
                "outgoing": call.isOutgoing,
                "connected": call.hasConnected,
                "ended": call.hasEnded,
                "onHold": call.isOnHold
            ]
        }

        let audioSession = AVAudioSession.sharedInstance()
        diagnostics["audioCategory"] = audioSession.category.rawValue
        diagnostics["audioMode"] = audioSession.mode.rawValue
        diagnostics["audioRoute"] = audioSession.currentRoute.outputs.map { $0.portType.rawValue }
        diagnostics["inputAvailable"] = audioSession.isInputAvailable
        diagnostics["otherAudioPlaying"] = audioSession.isOtherAudioPlaying

        if let lastError = lastCallKitReportError {
            diagnostics["lastCallKitError"] = lastError
        }
        if let timestamp = lastCallKitReportTimestamp {
            diagnostics["msSinceCallKitReport"] = millisecondsSince(timestamp)
        }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            var enriched = diagnostics
            enriched["notificationAuthorization"] = self.authorizationStatusDescription(settings.authorizationStatus)
            enriched["notificationAlertSetting"] = self.notificationSettingDescription(settings.alertSetting)
            self.emitDiagnostics(enriched, scope: "incoming-call")
        }
    }

    private func emitDiagnostics(_ payload: [String: Any], scope: String) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8) {
            sendPhoneCallEvents(description: "DIAG|\(scope)|\(json)", isError: false)
        } else {
            sendPhoneCallEvents(description: "DIAG|\(scope)|\(String(describing: payload))", isError: false)
        }
    }

    private func currentApplicationState() -> UIApplication.State {
        if Thread.isMainThread {
            return UIApplication.shared.applicationState
        }
        var state = UIApplication.State.inactive
        DispatchQueue.main.sync {
            state = UIApplication.shared.applicationState
        }
        return state
    }

    private func applicationStateDescription(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func currentAPNsRegistrationState() -> Bool {
        if Thread.isMainThread {
            return UIApplication.shared.isRegisteredForRemoteNotifications
        }
        var registered = false
        DispatchQueue.main.sync {
            registered = UIApplication.shared.isRegisteredForRemoteNotifications
        }
        return registered
    }

    private func authorizationStatusDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func notificationSettingDescription(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "notSupported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }

    private func millisecondsSince(_ date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func stringifyCustomParameters(_ params: [String: Any]?) -> [String: String] {
        guard let params = params else { return [:] }
        var sanitized: [String: String] = [:]
        for (key, value) in params {
            sanitized[key] = String(describing: value)
        }
        return sanitized
    }

    private func summarizeVoipPayload(_ payload: [AnyHashable: Any]) -> [String: String] {
        var summary: [String: String] = [:]
        let interestingKeys: Set<String> = [
            "twi_call_sid",
            "twi_call_id",
            "twi_message_type",
            "twi_to",
            "twi_from",
            "twi_bridge_token",
            "From",
            "To"
        ]

        for (rawKey, value) in payload {
            guard let key = rawKey as? String else { continue }
            if interestingKeys.contains(key) {
                summary[key] = String(describing: value)
            }
        }

        if summary.isEmpty {
            let keys = payload.keys.compactMap { $0 as? String }
            if !keys.isEmpty {
                summary["keys"] = keys.sorted().joined(separator: ",")
            }
        }
        return summary
    }
    
    private func sendPhoneCallEvents(description: String, isError: Bool) {
        // NSLog(description)
        
        // if isError
        // {
        //     let err = FlutterError(code: "unavailable", message: description, details: nil);
        //     sendEvent(err)
        // }
        // else
        // {
        //     sendEvent(description)
        // }
        // ── debounce duplicate events ───────────────────────
        let now = Date()
        if description == lastLoggedEvent,
            let lastTime = lastLoggedTime,
            now.timeIntervalSince(lastTime) < 1.0 {
            return
        }
        lastLoggedEvent = description
        lastLoggedTime = now
        // ── end debounce ───────────────────────────────────

        // existing logic
        NSLog(description)
        if isError {
            let err = FlutterError(code: "unavailable", message: description, details: nil)
            sendEvent(err)
        } else {
            sendEvent(description)
        }
    }
    
    private func sendEvent(_ event: Any) {
        guard let eventSink = eventSink else {
            return
        }
        DispatchQueue.main.async {
            eventSink(event)
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let type = userInfo["type"] as? String, type == "twilio-missed-call", let user = userInfo["From"] as? String{
            self.callTo = user
            if let to = userInfo["To"] as? String{
                self.identity = to
            }
            makeCall(to: callTo)
            completionHandler()
            self.sendPhoneCallEvents(description: "ReturningCall|\(identity)|\(user)|Outgoing", isError: false)
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "twilio-missed-call"{
            completionHandler([.alert])
        }
    }

     /// Serialize + save a [String:Any] dictionary
    private func saveCustomParams(_ params: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params, options: []),
              let json = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(json, forKey: kCustomParamsKey)
    }

    /// Read back the dictionary (if any)
    private func getCustomParams() -> [String:Any]? {
        guard let json = UserDefaults.standard.string(forKey: kCustomParamsKey),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any]
        else { return nil }
        return dict
    }

    /// Remove it when the call ends
    private func clearCustomParams() {
        UserDefaults.standard.removeObject(forKey: kCustomParamsKey)
    }
    
}

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        guard let rootViewController = self.rootViewController else {
            return nil
        }
        return topViewController(for: rootViewController)
    }
    
    func topViewController(for rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController = rootViewController else {
            return nil
        }
        guard let presentedViewController = rootViewController.presentedViewController else {
            return rootViewController
        }
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

//    private func saveCustomParams(_ params: [String:Any]) {
//         // 1) serialize to JSON
//         guard let data = try? JSONSerialization.data(withJSONObject: params, options: []),
//               let json = String(data: data, encoding: .utf8)
//         else { return }
//         // 2) persist string
//         UserDefaults.standard.set(json, forKey: kCustomParamsKey)
//     }

//     private func getCustomParams() -> [String:Any]? {
//         guard let json = UserDefaults.standard.string(forKey: kCustomParamsKey),
//               let data = json.data(using: .utf8),
//               let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any]
//         else { return nil }
//         return dict
//     }

//     private func clearCustomParams() {
//         UserDefaults.standard.removeObject(forKey: kCustomParamsKey)
//     }
}
extension UserDefaults {
    public func optionalBool(forKey defaultName: String) -> Bool? {
        if let value = value(forKey: defaultName) {
            return value as? Bool
        }
        return nil
    }
}
