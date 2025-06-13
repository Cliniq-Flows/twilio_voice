package com.twilio.twilio_voice.types

/**  
 * Holds process-wide state that both the plugin and the ConnectionService can read.  
 */
object AppState {
  /** true when your Flutter Activity is in front */
  @Volatile
  var isFlutterForeground: Boolean = false
}