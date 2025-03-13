import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';
import '../platform_interface/twilio_call_platform_interface.dart';

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

  /// Places new call.
  ///
  /// [extraOptions] will be added to the call payload.
  @override
  Future<bool?> place({
    required String from,
    required String to,
    Map<String, dynamic>? extraOptions,
  }) {
    _activeCall =
        ActiveCall(from: from, to: to, callDirection: CallDirection.outgoing);
    var options = extraOptions ?? <String, dynamic>{};
    options['From'] = from;
    options['To'] = to;
    return _channel.invokeMethod('makeCall', options);
  }

  /// Hangs up active call.
  ///
  /// Optionally specify a [callId] (UUID string) to hang up a particular call.
  @override
  Future<bool?> hangUp({String? callId}) {
    var params = <String, dynamic>{};
    if (callId != null) {
      params['callId'] = callId;
    }
    return _channel.invokeMethod('hangUp', params);
  }

  /// Checks if there is an ongoing call.
  @override
  Future<bool> isOnCall() {
    return _channel.invokeMethod<bool?>('isOnCall',
        <String, dynamic>{}).then<bool>((bool? value) => value ?? false);
  }

  /// Gets the active call's SID.
  @override
  Future<String?> getSid() {
    return _channel.invokeMethod<String?>('call-sid', <String, dynamic>{});
  }

  /// Answers an incoming call.
  @override
  Future<bool?> answer() {
    return _channel.invokeMethod('answer', <String, dynamic>{});
  }

  /// Holds active call.
  ///
  /// [holdCall] toggles the hold state. Optionally specify a [callId].
  @override
  Future<bool?> holdCall({bool holdCall = true, String? callId}) {
    var params = <String, dynamic>{"shouldHold": holdCall};
    if (callId != null) {
      params['callId'] = callId;
    }
    return _channel.invokeMethod('holdCall', params);
  }

  /// Queries the active call's holding state.
  ///
  /// Optionally specify a [callId].
  @override
  Future<bool?> isHolding({String? callId}) {
    var params = <String, dynamic>{};
    if (callId != null) {
      params['callId'] = callId;
    }
    return _channel.invokeMethod('isHolding', params);
  }

  /// Toggles mute state.
  ///
  /// Optionally specify a [callId].
  @override
  Future<bool?> toggleMute(bool isMuted, {String? callId}) {
    var params = <String, dynamic>{"muted": isMuted};
    if (callId != null) {
      params['callId'] = callId;
    }
    return _channel.invokeMethod('toggleMute', params);
  }

  /// Queries the mute status of the call.
  ///
  /// Optionally specify a [callId].
  @override
  Future<bool?> isMuted({String? callId}) {
    var params = <String, dynamic>{};
    if (callId != null) {
      params['callId'] = callId;
    }
    return _channel.invokeMethod('isMuted', params);
  }

  /// Toggles the speaker state.
  @override
  Future<bool?> toggleSpeaker(bool speakerIsOn) {
    return _channel.invokeMethod(
        'toggleSpeaker', <String, dynamic>{"speakerIsOn": speakerIsOn});
  }

  /// Checks if the speaker is active.
  @override
  Future<bool?> isOnSpeaker() {
    return _channel.invokeMethod('isOnSpeaker', <String, dynamic>{});
  }

  /// Sends DTMF digits during a call.
  @override
  Future<bool?> sendDigits(String digits) {
    return _channel
        .invokeMethod('sendDigits', <String, dynamic>{"digits": digits});
  }

  /// Toggles the Bluetooth state.
  @override
  Future<bool?> toggleBluetooth({bool bluetoothOn = true}) {
    return _channel.invokeMethod(
        'toggleBluetooth', <String, dynamic>{"bluetoothOn": bluetoothOn});
  }

  /// Checks if Bluetooth is active.
  @override
  Future<bool?> isBluetoothOn() {
    return _channel.invokeMethod('isBluetoothOn', <String, dynamic>{});
  }

  /// Only web supported for now.
  @override
  Future<bool?> connect({Map<String, dynamic>? extraOptions}) {
    return Future.value(false);
  }

  /// Swaps active and held calls if exactly two calls exist.
  Future<bool?> swapCalls() {
    return _channel.invokeMethod('swapCalls', <String, dynamic>{});
  }
}
