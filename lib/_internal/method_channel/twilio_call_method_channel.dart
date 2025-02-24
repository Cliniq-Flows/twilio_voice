// import 'package:flutter/services.dart';
// import 'package:twilio_voice/twilio_voice.dart';

// import '../platform_interface/twilio_call_platform_interface.dart';

// // abstract class MethodChannelTwilioCall extends TwilioVoiceSharedPlatform {
// class MethodChannelTwilioCall extends TwilioCallPlatform {
//   ActiveCall? _activeCall;

//   @override
//   ActiveCall? get activeCall => _activeCall;

//   @override
//   set activeCall(ActiveCall? activeCall) {
//     _activeCall = activeCall;
//   }

//   MethodChannel get _channel => sharedChannel;

//   MethodChannelTwilioCall();

//   /// Places new call
//   ///
//   /// [extraOptions] will be added to the callPayload sent to your server
//   @override
//   Future<bool?> place(
//       {required String from,
//       required String to,
//       Map<String, dynamic>? extraOptions}) {
//     _activeCall =
//         ActiveCall(from: from, to: to, callDirection: CallDirection.outgoing);

//     var options = extraOptions ?? <String, dynamic>{};
//     options['From'] = from;
//     options['To'] = to;
//     return _channel.invokeMethod('makeCall', options);
//   }

//   /// Hangs up active call
//   @override
//   Future<bool?> hangUp() {
//     return _channel.invokeMethod('hangUp', <String, dynamic>{});
//   }

//   /// Checks if there is an ongoing call
//   @override
//   Future<bool> isOnCall() {
//     return _channel.invokeMethod<bool?>('isOnCall',
//         <String, dynamic>{}).then<bool>((bool? value) => value ?? false);
//   }

//   /// Gets the active call's SID. This will be null until the first Ringing event occurs
//   @override
//   Future<String?> getSid() {
//     return _channel.invokeMethod<String?>('call-sid',
//         <String, dynamic>{}).then<String?>((String? value) => value);
//   }

//   /// Answers incoming call
//   @override
//   Future<bool?> answer() {
//     return _channel.invokeMethod('answer', <String, dynamic>{});
//   }

//   /// Holds active call
//   /// [holdCall] is respected in web only, in native it will always toggle the hold state.
//   /// In future, native mobile will also respect the [holdCall] value.
//   @override
//   Future<bool?> holdCall({bool holdCall = true}) {
//     return _channel
//         .invokeMethod('holdCall', <String, dynamic>{"shouldHold": holdCall});
//   }

//   /// Query's active call holding state
//   @override
//   Future<bool?> isHolding() {
//     return _channel.invokeMethod('isHolding', <String, dynamic>{});
//   }

//   /// Toggles mute state to provided value
//   @override
//   Future<bool?> toggleMute(bool isMuted) {
//     return _channel
//         .invokeMethod('toggleMute', <String, dynamic>{"muted": isMuted});
//   }

//   /// Query's mute status of call, true if call is muted
//   @override
//   Future<bool?> isMuted() {
//     return _channel.invokeMethod('isMuted', <String, dynamic>{});
//   }

//   /// Toggles speaker state to provided value
//   @override
//   Future<bool?> toggleSpeaker(bool speakerIsOn) {
//     return _channel.invokeMethod(
//         'toggleSpeaker', <String, dynamic>{"speakerIsOn": speakerIsOn});
//   }

//   /// Switches Audio Device
//   /*Future<String?> switchAudio({String audioDevice = "auto}) {
//     return _channel.invokeMethod('switchAudio', <String, dynamic>{"audioDevice": audioDevice});
//   }*/

//   /// Query's speaker output status, true if on loud speaker.
//   @override
//   Future<bool?> isOnSpeaker() {
//     return _channel.invokeMethod('isOnSpeaker', <String, dynamic>{});
//   }

//   @override
//   Future<bool?> sendDigits(String digits) {
//     return _channel
//         .invokeMethod('sendDigits', <String, dynamic>{"digits": digits});
//   }

//   @override
//   Future<bool?> toggleBluetooth({bool bluetoothOn = true}) {
//     return _channel.invokeMethod(
//         'toggleBluetooth', <String, dynamic>{"bluetoothOn": bluetoothOn});
//   }

//   @override
//   Future<bool?> isBluetoothOn() {
//     return _channel.invokeMethod('isBluetoothOn', <String, dynamic>{});
//   }

//   /// Only web supported for now.
//   @override
//   Future<bool?> connect({Map<String, dynamic>? extraOptions}) {
//     return Future.value(false);
//   }
// }
import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../platform_interface/twilio_call_platform_interface.dart';

/// An updated MethodChannel implementation that supports multiple calls
/// by sending a call identifier (callUUID) with each method call.
class MethodChannelTwilioCall extends TwilioCallPlatform {
  ActiveCall? _activeCall;

  @override
  ActiveCall? get activeCall => _activeCall;

  @override
  set activeCall(ActiveCall? activeCall) {
    _activeCall = activeCall;
  }

  MethodChannel get _channel => sharedChannel;

  MethodChannelTwilioCall();

  /// Places a new outgoing call.
  ///
  /// The [extraOptions] map must include parameters required by native,
  /// and native will generate a callUUID which should be saved to the active call.
  @override
  Future<bool?> place({
    required String from,
    required String to,
    Map<String, dynamic>? extraOptions,
  }) async {
    // Create a new ActiveCall instance.
    // Make sure your ActiveCall model has an optional property for callUUID.
    _activeCall =
        ActiveCall(from: from, to: to, callDirection: CallDirection.outgoing);

    var options = extraOptions ?? <String, dynamic>{};
    options['From'] = from;
    options['To'] = to;
    // You may include other required options like accessToken if needed.
    final result = await _channel.invokeMethod<bool>('makeCall', options);

    // Optionally, you might listen for events from the native side (via the event channel)
    // that include the callUUID. When you receive it, assign it to _activeCall.
    // For example:
    // _activeCall!.callUUID = receivedCallUUID;

    return result;
  }

  /// Hangs up the active call.
  ///
  /// This now sends the active call’s unique identifier to the native side.
  @override
  Future<bool?> hangUp() {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'hangUp',
      <String, dynamic>{
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Checks if there is an ongoing call.
  @override
  Future<bool> isOnCall() {
    return _channel.invokeMethod<bool>('isOnCall',
        <String, dynamic>{}).then<bool>((bool? value) => value ?? false);
  }

  /// Gets the active call's SID or call identifier.
  @override
  Future<String?> getSid() {
    return _channel.invokeMethod<String>('call-sid', <String, dynamic>{});
  }

  /// Answers an incoming call.
  ///
  /// On native side the answer action will find the call invite by its UUID.
  @override
  Future<bool?> answer() {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'answer',
      <String, dynamic>{
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Holds or unholds the active call.
  ///
  /// The method sends both the desired hold state and the call’s unique identifier.
  @override
  Future<bool?> holdCall({bool holdCall = true}) {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'holdCall',
      <String, dynamic>{
        "shouldHold": holdCall,
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Queries whether the active call is holding.
  ///
  /// The native side is expected to return the hold status for the call.
  @override
  Future<bool?> isHolding() {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'isHolding',
      <String, dynamic>{
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Toggles the mute state of the active call.
  @override
  Future<bool?> toggleMute(bool isMuted) {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'toggleMute',
      <String, dynamic>{
        "muted": isMuted,
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Queries the mute status of the active call.
  @override
  Future<bool?> isMuted() {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'isMuted',
      <String, dynamic>{
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Toggles the speaker output state.
  @override
  Future<bool?> toggleSpeaker(bool speakerIsOn) {
    return _channel.invokeMethod(
      'toggleSpeaker',
      <String, dynamic>{
        "speakerIsOn": speakerIsOn,
      },
    );
  }

  /// Queries if the speaker is active.
  @override
  Future<bool?> isOnSpeaker() {
    return _channel.invokeMethod('isOnSpeaker', <String, dynamic>{});
  }

  /// Sends DTMF digits for the active call.
  @override
  Future<bool?> sendDigits(String digits) {
    if (_activeCall?.callUUID == null) {
      return Future.value(false);
    }
    return _channel.invokeMethod(
      'sendDigits',
      <String, dynamic>{
        "digits": digits,
        "callUUID": _activeCall!.callUUID,
      },
    );
  }

  /// Toggles Bluetooth connectivity.
  @override
  Future<bool?> toggleBluetooth({bool bluetoothOn = true}) {
    return _channel.invokeMethod(
      'toggleBluetooth',
      <String, dynamic>{
        "bluetoothOn": bluetoothOn,
      },
    );
  }

  /// Checks if Bluetooth is active.
  @override
  Future<bool?> isBluetoothOn() {
    return _channel.invokeMethod('isBluetoothOn', <String, dynamic>{});
  }

  /// For platforms other than native mobile.
  @override
  Future<bool?> connect({Map<String, dynamic>? extraOptions}) {
    return Future.value(false);
  }
}
