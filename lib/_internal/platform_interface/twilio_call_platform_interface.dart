import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../twilio_voice.dart';
import '../method_channel/twilio_call_method_channel.dart';
import 'shared_platform_interface.dart';

abstract class TwilioCallPlatform extends SharedPlatformInterface {
  TwilioCallPlatform() : super(token: _token);

  static final Object _token = Object();

  static TwilioCallPlatform _instance = MethodChannelTwilioCall();

  static TwilioCallPlatform get instance => _instance;

  static set instance(TwilioCallPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Gets active call.
  ActiveCall? get activeCall;

  /// Sets active call.
  set activeCall(ActiveCall? activeCall);

  /// Places new call.
  ///
  /// [extraOptions] will be added to the call payload sent to your server.
  Future<bool?> place({
    required String from,
    required String to,
    Map<String, dynamic>? extraOptions,
  });

  /// Place outgoing call with raw parameters. Returns true if successful.
  ///
  /// [extraOptions] will be added to the call payload sent to your server.
  Future<bool?> connect({Map<String, dynamic>? extraOptions});

  /// Hangs up a call.
  ///
  /// Optionally specify a [callId] (UUID string) to hang up a specific call.
  Future<bool?> hangUp({String? callId});

  /// Checks if there is an ongoing call.
  Future<bool> isOnCall();

  /// Gets the active call's SID. This will be null until the first Ringing event occurs.
  Future<String?> getSid();

  /// Answers an incoming call.
  Future<bool?> answer();

  /// Puts a call on hold.
  ///
  /// [holdCall] determines whether to hold (true) or unhold (false) the call.
  /// Optionally specify a [callId] to target a specific call.
  Future<bool?> holdCall({bool holdCall = true, String? callId});

  /// Queries the holding status of a call.
  ///
  /// Optionally specify a [callId] to target a specific call.
  Future<bool?> isHolding({String? callId});

  /// Toggles the mute state of a call.
  ///
  /// Optionally specify a [callId] to target a specific call.
  Future<bool?> toggleMute(bool isMuted, {String? callId});

  /// Queries the mute status of a call.
  ///
  /// Optionally specify a [callId] to target a specific call.
  Future<bool?> isMuted({String? callId});

  /// Toggles the speaker state of the call.
  Future<bool?> toggleSpeaker(bool speakerIsOn);

  /// Checks if the speaker output is active.
  Future<bool?> isOnSpeaker();

  /// Toggles Bluetooth for the active call.
  Future<bool?> toggleBluetooth({bool bluetoothOn = true});

  /// Queries the Bluetooth status.
  Future<bool?> isBluetoothOn();

  /// Sends DTMF digits to the active call.
  Future<bool?> sendDigits(String digits);

  /// Swaps the active and held calls when two concurrent calls exist.
  Future<bool?> swapCalls();

  /// Connects to a conference call using the specified [conferenceName].
  ///
  /// [extraOptions] will be added to the call payload sent to your server.
  Future<bool?> connectToConference({
    required String conferenceName,
  });
}
