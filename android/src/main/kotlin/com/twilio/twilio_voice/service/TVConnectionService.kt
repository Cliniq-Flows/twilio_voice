package com.twilio.twilio_voice.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.*
import android.util.Log
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import org.json.JSONObject
import com.twilio.twilio_voice.R
import com.twilio.twilio_voice.call.TVCallInviteParametersImpl
import com.twilio.twilio_voice.call.TVCallParametersImpl
import com.twilio.twilio_voice.call.TVParameters
import com.twilio.twilio_voice.fcm.VoiceFirebaseMessagingService
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.storage.Storage
import com.twilio.twilio_voice.storage.StorageImpl
import com.twilio.twilio_voice.types.BundleExtensions.getParcelableSafe
import com.twilio.twilio_voice.types.CallDirection
import com.twilio.twilio_voice.types.CompletionHandler
import com.twilio.twilio_voice.types.ContextExtension.appName
import com.twilio.twilio_voice.types.ContextExtension.hasCallPhonePermission
import com.twilio.twilio_voice.types.ContextExtension.hasManageOwnCallsPermission
import com.twilio.twilio_voice.types.IntentExtension.getParcelableExtraSafe
import com.twilio.twilio_voice.types.TVNativeCallEvents
import com.twilio.twilio_voice.types.TelecomManagerExtension.getPhoneAccountHandle
import com.twilio.twilio_voice.types.TelecomManagerExtension.hasCallCapableAccount
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneState
import com.twilio.twilio_voice.types.TelecomManagerExtension.registerPhoneAccount
import com.twilio.twilio_voice.types.ValueBundleChanged
import com.twilio.voice.*
import com.twilio.voice.Call

class TVConnectionService : ConnectionService() {

    companion object {
        val TAG = "TwilioVoiceConnectionService"

        val activeConnections = HashMap<String, TVCallConnection>()

        val TWI_SCHEME: String = "twi"

        val SERVICE_TYPE_MICROPHONE: Int = 100

         // ─── NEW: Conference Call ACTION and EXTRA ───────────────────────────────
        const val ACTION_CONNECT_TO_CONFERENCE: String = "ACTION_CONNECT_TO_CONFERENCE"
        const val EXTRA_CONFERENCE_NAME: String = "EXTRA_CONFERENCE_NAME"
        // ─────────────────────────────────────────────────────────────────────────────

        const val ACTION_UPDATE_DISPLAY_NAME: String = "updateDisplayName"




        //region ACTIONS_* Constants
        /**
         * Action used with [VoiceFirebaseMessagingService] to notify of incoming calls
         */
        const val ACTION_CALL_INVITE: String = "ACTION_CALL_INVITE"

        //region ACTIONS_* Constants
        /**
         * Action used with [EXTRA_CALL_HANDLE] to cancel a call connection.
         */
        const val ACTION_CANCEL_CALL_INVITE: String = "ACTION_CANCEL_CALL_INVITE"

        /**
         * Action used with [EXTRA_DIGITS] to send digits to the [TVConnection] active call.
         */
        const val ACTION_SEND_DIGITS: String = "ACTION_SEND_DIGITS"

        /**
         * Action used to hangup an active call connection.
         */
        const val ACTION_HANGUP: String = "ACTION_HANGUP"

        /**
         * Action used to toggle the speakerphone state of an active call connection.
         */
        const val ACTION_TOGGLE_SPEAKER: String = "ACTION_TOGGLE_SPEAKER"

        /**
         * Action used to toggle bluetooth state of an active call connection.
         */
        const val ACTION_TOGGLE_BLUETOOTH: String = "ACTION_TOGGLE_BLUETOOTH"

        /**
         * Action used to toggle hold state of an active call connection.
         */
        const val ACTION_TOGGLE_HOLD: String = "ACTION_TOGGLE_HOLD"

        /**
         * Action used to toggle mute state of an active call connection.
         */
        const val ACTION_TOGGLE_MUTE: String = "ACTION_TOGGLE_MUTE"

        /**
         * Action used to answer an incoming call connection.
         */
        const val ACTION_ANSWER: String = "ACTION_ANSWER"

        /**
         * Action used to answer an incoming call connection.
         */
        const val ACTION_INCOMING_CALL: String = "ACTION_INCOMING_CALL"

        /**
         * Action used to place an outgoing call connection.
         * Additional parameters are required: [EXTRA_TOKEN], [EXTRA_TO] and [EXTRA_FROM]. Optionally, [EXTRA_OUTGOING_PARAMS] for bundled extra custom parameters.
         */
        const val ACTION_PLACE_OUTGOING_CALL: String = "ACTION_PLACE_OUTGOING_CALL"

        /**
         * Action used to poll the ConnectionService for the active call handle.
         */
        const val ACTION_ACTIVE_HANDLE: String = "ACTION_ACTIVE_HANDLE"
        //endregion

        //region EXTRA_* Constants
        /**
         * Extra used with [ACTION_SEND_DIGITS] to send digits to the [TVConnection] active call.
         */
        const val EXTRA_DIGITS: String = "EXTRA_DIGITS"

        /**
         * Extra used with [ACTION_CANCEL_CALL_INVITE] to cancel a call connection.
         */
        const val EXTRA_INCOMING_CALL_INVITE: String = "EXTRA_INCOMING_CALL_INVITE"

        /**
         * Extra used to identify a call connection.
         */
        const val EXTRA_CALL_HANDLE: String = "EXTRA_CALL_HANDLE"

        /**
         * Extra used with [ACTION_CANCEL_CALL_INVITE] to cancel a call connection
         */
        const val EXTRA_CANCEL_CALL_INVITE: String = "EXTRA_CANCEL_CALL_INVITE"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection. Denotes the Twilio Voice access token.
         */
        const val EXTRA_TOKEN: String = "EXTRA_TOKEN"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection. Denotes the recipient's identity.
         */
        const val EXTRA_TO: String = "EXTRA_TO"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection. Denotes the caller's identity.
         */
        const val EXTRA_FROM: String = "EXTRA_FROM"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to send additional parameters to the [TVConnectionService] active call.
         */
        const val EXTRA_OUTGOING_PARAMS: String = "EXTRA_OUTGOING_PARAMS"

        /**
         * Extra used with [ACTION_TOGGLE_SPEAKER] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_SPEAKER_STATE: String = "EXTRA_SPEAKER_STATE"

        /**
         * Extra used with [ACTION_TOGGLE_BLUETOOTH] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_BLUETOOTH_STATE: String = "EXTRA_BLUETOOTH_STATE"

        /**
         * Extra used with [ACTION_TOGGLE_HOLD] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_HOLD_STATE: String = "EXTRA_HOLD_STATE"

        /**
         * Extra used with [ACTION_TOGGLE_MUTE] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_MUTE_STATE: String = "EXTRA_MUTE_STATE"
        //endregion

        fun hasActiveCalls(): Boolean {
            return activeConnections.isNotEmpty()
        }

        /**
         * Active call definition is extended to include calls in which one can actively communicate, or call is on hold, or call is ringing or dialing. This applies only to this and calling functions.
         * Gets the first ongoing call handle, if any. Else, gets the first call on hold. Lastly, gets the first call in either a ringing or dialing state, if any. Returns null if there are no active calls. If there are more than one active calls, the first call handle is returned.
         * Note: this might not necessarily correspond to the current active call.
         */
        fun getActiveCallHandle(): String? {
            if (!hasActiveCalls()) return null
            return activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_ACTIVE }?.key
                ?: activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_HOLDING }?.key
                ?: activeConnections.entries.firstOrNull { arrayListOf(Connection.STATE_RINGING, Connection.STATE_DIALING).contains(it.value.state) }?.key
        }

        fun getIncomingCallHandle(): String? {
            if (!hasActiveCalls()) return null
            return activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_RINGING }?.key
        }

        fun getConnection(callSid: String): TVCallConnection? {
            return activeConnections[callSid]
        }
    }

    private val storage: Storage by lazy { StorageImpl(applicationContext) }
    private fun stopSelfSafe(): Boolean {
        if (!hasActiveCalls()) {
            stopSelf()
            return true
        } else {
            return false
        }
    }

    //region Service onStartCommand
    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Thread.currentThread().contextClassLoader = CallInvite::class.java.classLoader
        super.onStartCommand(intent, flags, startId)
        intent?.let {
            when (it.action) {
                ACTION_SEND_DIGITS -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_SEND_DIGITS is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val digits = it.getStringExtra(EXTRA_DIGITS) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_SEND_DIGITS is missing String EXTRA_DIGITS")
                        return@let
                    }

                    getConnection(callHandle)?.sendDigits(digits) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_SEND_DIGITS] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_CANCEL_CALL_INVITE -> {
                    // Load CancelledCallInvite class loader
                    // See: https://github.com/twilio/voice-quickstart-android/issues/561#issuecomment-1678613170
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    val cancelledCallInvite = it.getParcelableExtraSafe<CancelledCallInvite>(EXTRA_CANCEL_CALL_INVITE) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_CANCEL_CALL_INVITE is missing parcelable EXTRA_CANCEL_CALL_INVITE")
                        return@let
                    }
                     storage.clearCustomParams()
                    val callHandle = cancelledCallInvite.callSid
                    getConnection(callHandle)?.onAbort() ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_CANCEL_CALL_INVITE] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_INCOMING_CALL -> {
                    // Load CallInvite class loader & get callInvite
                    val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE) ?: run {
                        Log.e(TAG, "onStartCommand: 'ACTION_INCOMING_CALL' is missing parcelable 'EXTRA_INCOMING_CALL_INVITE'")
                        return@let
                    }

                    // Extract firstname and lastname from the custom parameters (if available)
                    val firstName = callInvite.customParameters["firstname"] ?: ""
                    val lastName = callInvite.customParameters["lastname"] ?: ""
                    // Also clean up the default 'from' value (remove any unwanted prefix)
                    var fromCleaned = callInvite.from ?: ""
                    fromCleaned = fromCleaned.replace("client:", "")

                    val incomingJson = JSONObject(callInvite.customParameters).toString()
                    storage.saveCustomParams(incomingJson)
                     // Log or send events as needed (similar to your iOS logging)
                    Log.d(TAG, "Ringing | $firstName | ${callInvite.to} | Incoming - customParams: ${callInvite.customParameters}")

                    // Optionally, create a display name by combining firstname and lastname
                    val displayName = "$firstName $lastName".trim()

                    val telecomManager = getSystemService(TELECOM_SERVICE) as TelecomManager
                    if (!telecomManager.canReadPhoneState(applicationContext)) {
                        Log.e(TAG, "onCallInvite: Permission to read phone state not granted or requested.")
                        callInvite.reject(applicationContext)
                        return@let
                    }

                    val phoneAccountHandle = telecomManager.getPhoneAccountHandle(applicationContext)
                    val phoneAccount = telecomManager.getPhoneAccount(phoneAccountHandle)
                    if(phoneAccount == null) {
                        Log.e(TAG, "onStartCommand: PhoneAccount is null, make sure to register one with `registerPhoneAccount()`")
                        return@let
                    }
                    if(!phoneAccount.isEnabled) {
                        Log.e(TAG, "onStartCommand: PhoneAccount is not enabled, prompt the user to enable the phone account by opening settings with `openPhoneAccountSettings()`")
                        return@let
                    }

                    // Get telecom manager
                    if (!telecomManager.hasCallCapableAccount(applicationContext, phoneAccountHandle.componentName.className)) {
                        Log.e(
                            TAG, "onCallInvite: No registered phone account for PhoneHandle $phoneAccountHandle.\n" +
                                    "Check the following:\n" +
                                    "- Have you requested READ_PHONE_STATE permissions\n" +
                                    "- Have you registered a PhoneAccount \n" +
                                    "- Have you activated the Calling Account?"
                        )
                        callInvite.reject(applicationContext)
                        return@let
                    }

                    val myBundle: Bundle = Bundle().apply {
                        putParcelable(EXTRA_INCOMING_CALL_INVITE, callInvite)
                         // Set the Telecom call subject only if displayName is not empty
                        if (displayName.isNotEmpty()) {
                            putString(TelecomManager.EXTRA_CALL_SUBJECT, displayName)
                        }
                    }
                    myBundle.classLoader = CallInvite::class.java.classLoader

                    // Add extras for [addNewIncomingCall] method
                    val extras = Bundle().apply {
                        putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, myBundle)
                        putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, phoneAccountHandle)

                        // if (callInvite.customParameters.containsKey("_TWI_SUBJECT")) {
                        //     putString(TelecomManager.EXTRA_CALL_SUBJECT, callInvite.customParameters["_TWI_SUBJECT"])
                        // }
                         if (displayName.isNotEmpty()) {
                            putString(TelecomManager.EXTRA_CALL_SUBJECT, displayName)
                        }
                       
                    }




                    // Add new incoming call to the telecom manager
                    telecomManager.addNewIncomingCall(phoneAccountHandle, extras)
                }

                ACTION_ANSWER -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getIncomingCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_HANGUP is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }

                    val connection = getConnection(callHandle) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_HANGUP] could not find connection for callHandle: $callHandle")
                        return@let
                    }

                    if(connection is TVCallInviteConnection) {
                        connection.acceptInvite()
                    } else {
                        Log.e(TAG, "onStartCommand: [ACTION_ANSWER] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_HANGUP -> {
                    storage.clearCustomParams()
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_HANGUP is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }

                    getConnection(callHandle)?.disconnect() ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_HANGUP] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_PLACE_OUTGOING_CALL -> {
                    // check required EXTRA_TOKEN, EXTRA_TO, EXTRA_FROM
                    val token = it.getStringExtra(EXTRA_TOKEN) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TOKEN")
                        return@let
                    }
                    val to = it.getStringExtra(EXTRA_TO) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TO")
                        return@let
                    }
                    val from = it.getStringExtra(EXTRA_FROM) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_FROM")
                        return@let
                    }

                    // Get all params from bundle
                    val params = HashMap<String, String>()
                    val outGoingParams = it.getParcelableExtraSafe<Bundle>(EXTRA_OUTGOING_PARAMS)
                    outGoingParams?.keySet()?.forEach { key ->
                        outGoingParams.getString(key)?.let { value ->
                            params[key] = value
                        }
                    }

                    val outgoingJson = JSONObject(params as Map<*, *>).toString()
                    storage.saveCustomParams(outgoingJson)

                    // Add required params
                    params[EXTRA_FROM] = from
                    params[EXTRA_TO] = to
                    params[EXTRA_TOKEN] = token

                    // Create Twilio Param bundles
                    val myBundle = Bundle().apply {
                        putBundle(EXTRA_OUTGOING_PARAMS, Bundle().apply {
                            params.forEach { (key, value) ->
                                putString(key, value)
                            }
                        })
                    }

                    val telecomManager = getSystemService(TELECOM_SERVICE) as TelecomManager
                    val phoneAccountHandle = telecomManager.getPhoneAccountHandle(applicationContext)

                    if (!telecomManager.canReadPhoneState(applicationContext)) {
                        Log.e(TAG, "onStartCommand: Missing READ_PHONE_STATE permission")
                        return@let
                    }

                    val phoneAccount = telecomManager.getPhoneAccount(phoneAccountHandle)
                    if(phoneAccount == null) {
                        Log.e(TAG, "onStartCommand: PhoneAccount is null, make sure to register one with `registerPhoneAccount()`")
                        return@let
                    }
                    if(!phoneAccount.isEnabled) {
                        Log.e(TAG, "onStartCommand: PhoneAccount is not enabled, prompt the user to enable the phone account by opening settings with `openPhoneAccountSettings()`")
                        return@let
                    }

                    if (!telecomManager.hasCallCapableAccount(applicationContext, phoneAccountHandle.componentName.className)) {
                        Log.e(TAG, "onStartCommand: No registered phone account for PhoneHandle $phoneAccountHandle")
                        telecomManager.registerPhoneAccount(applicationContext, phoneAccountHandle)
                    }

                    if (!applicationContext.hasCallPhonePermission()) {
                        Log.e(TAG, "onStartCommand: Missing CALL_PHONE permission, request permission with `requestCallPhonePermission()`")
                        return@let
                    }

                    if (!applicationContext.hasManageOwnCallsPermission()) {
                        Log.e(TAG, "onStartCommand: Missing MANAGE_OWN_CALLS permission, request permission with `requestManageOwnCallsPermission()`")
                        return@let
                    }

                    // Create outgoing extras
                    val extras = Bundle().apply {
                        putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, phoneAccountHandle)
                        putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, myBundle)
                    }



                    val address: Uri = Uri.fromParts(PhoneAccount.SCHEME_TEL, to, null)
                    telecomManager.placeCall(address, extras)
                }

                ACTION_TOGGLE_BLUETOOTH -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_BLUETOOTH is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val bluetoothState = it.getBooleanExtra(EXTRA_BLUETOOTH_STATE, false)

                    getConnection(callHandle)?.toggleBluetooth(bluetoothState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_BLUETOOTH] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_TOGGLE_HOLD -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_HOLD is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val holdState = it.getBooleanExtra(EXTRA_HOLD_STATE, false)

                    getConnection(callHandle)?.toggleHold(holdState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_HOLD] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_TOGGLE_MUTE -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_MUTE is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val muteState = it.getBooleanExtra(EXTRA_MUTE_STATE, false)

                    getConnection(callHandle)?.toggleMute(muteState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_MUTE] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_TOGGLE_SPEAKER -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_SPEAKER is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val speakerState = it.getBooleanExtra(EXTRA_SPEAKER_STATE, false)
                    getConnection(callHandle)?.toggleSpeaker(speakerState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_SPEAKER] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_ACTIVE_HANDLE -> {
                    val activeCallHandle = getActiveCallHandle()
                    sendBroadcastCallHandle(applicationContext, activeCallHandle)
                }

                ACTION_UPDATE_DISPLAY_NAME -> {
                    val newDisplayName = it.getStringExtra("name")
                    /////
                    if (newDisplayName.isNullOrEmpty()) {
                        Log.e(TAG, "ACTION_UPDATE_DISPLAY_NAME: Missing display name extra")
                        return@let
                    }

                    val activeCallHandle = getActiveCallHandle()
                    if (activeCallHandle == null) {
                        Log.e(TAG, "ACTION_UPDATE_DISPLAY_NAME: No active call handle found")
                        return@let
                    }

                    val connection = getConnection(activeCallHandle)
                    if (connection != null) {
                        connection.setCallerDisplayName(newDisplayName, TelecomManager.PRESENTATION_ALLOWED)
                        Log.d(TAG, "Display name updated to: $newDisplayName for call: $activeCallHandle")
                        connection.setAddress(
                            Uri.fromParts(PhoneAccount.SCHEME_TEL, newDisplayName, null),
                            TelecomManager.PRESENTATION_ALLOWED
                        )
                    } else {
                        Log.e(TAG, "ACTION_UPDATE_DISPLAY_NAME: No connection found for call handle: $activeCallHandle")
                    }
                }

                // ─── New branch for conference connection ───────────────────────────────
                 ACTION_CONNECT_TO_CONFERENCE -> {
                     val conferenceName = intent.getStringExtra(EXTRA_CONFERENCE_NAME)
                     if (conferenceName.isNullOrEmpty()){
                         Log.e(TAG, "onStartCommand: ACTION_CONNECT_TO_CONFERENCE missing conference name")
                         return@let
                     }
                     // Pass the intent along with the conference name
                     joinConference(intent, conferenceName)
                 }

                // ─────────────────────────────────────────────────────────────────────────────

                else -> {
                    Log.e(TAG, "onStartCommand: unknown action: ${it.action}")
                }
            }
        } ?: run {
            Log.e(TAG, "onStartCommand: intent is null")
        }
        return START_STICKY
    }
    //endregion



//     // New function to join a conference call
   private fun joinConference(intent: Intent, conferenceName: String) {
     Log.d(TAG, "Joining conference: $conferenceName")

     val token = intent.getStringExtra(EXTRA_TOKEN) ?: ""
     if (token.isEmpty()) {
         Log.e(TAG, "joinConference: Access token is null or empty. Cannot join conference.")
         return
     }


     val params = HashMap<String, String>().apply {
         put("conference", conferenceName)  // Use lowercase key as in Swift
     }



     val connectOptions = ConnectOptions.Builder(token)
         .params(params)
         .build()



     val conferenceConnection = TVCallConnection(applicationContext)
     conferenceConnection.setInitializing()
     conferenceConnection.setDialing()
     conferenceConnection.twilioCall = Voice.connect(applicationContext, connectOptions, conferenceConnection)

     val tempId = "conference_$conferenceName"
     activeConnections[tempId] = conferenceConnection
       attachCallEventListeners(conferenceConnection, tempId)

     Log.d(TAG, "Conference call initiated with temporary ID: $tempId")
        conferenceConnection.setOnCallStateListener(CompletionHandler { state ->
              if (state == Call.State.RINGING || state == Call.State.CONNECTED) {
                   conferenceConnection.twilioCall?.sid?.let { sid ->
                          Log.d(TAG, "Conference SID is: $sid")

                          // swap out the temp key for the real SID
                          activeConnections.remove(tempId)
                          activeConnections[sid] = conferenceConnection

                          // fire the standard "EVENT_CONNECTED" broadcast
                          sendBroadcastEvent(
                                applicationContext,
                                TVNativeCallEvents.EVENT_CONNECTED,
                                sid,
                                Bundle().apply {
                                      putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, sid)
                                      putString(TVBroadcastReceiver.EXTRA_CALL_FROM, "Unknown Caller")      // or fill if you have a from
                                     putString(TVBroadcastReceiver.EXTRA_CALL_TO, "Unknown Caller")        // or fill if you have a to
                        putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION,
                            CallDirection.OUTGOING.id)
                                 }
                                )
                 }
          }
        })

  }



    override fun onCreateIncomingConnection(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        assert(request != null) { "ConnectionRequest cannot be null" }
        assert(connectionManagerPhoneAccount != null) { "ConnectionManagerPhoneAccount cannot be null" }

        super.onCreateIncomingConnection(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateIncomingConnection")

        val extras = request?.extras
        val myBundle: Bundle = extras?.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS) ?: run {
            Log.e(TAG, "onCreateIncomingConnection: request is missing Bundle EXTRA_INCOMING_CALL_EXTRAS")
            throw Exception("onCreateIncomingConnection: request is missing Bundle EXTRA_INCOMING_CALL_EXTRAS");
        }

        myBundle.classLoader = CallInvite::class.java.classLoader
        val ci: CallInvite = myBundle.getParcelableSafe(EXTRA_INCOMING_CALL_INVITE) ?: run {
            Log.e(TAG, "onCreateIncomingConnection: request is missing CallInvite EXTRA_INCOMING_CALL_INVITE")
            throw Exception("onCreateIncomingConnection: request is missing CallInvite EXTRA_INCOMING_CALL_INVITE");
        }

            // Extract custom display name components
            val firstName = ci.customParameters["firstname"] ?: ""
            val lastName = ci.customParameters["lastname"] ?: ""
            // Use custom display name if available, otherwise default to callInvite.from
            val displayName = if (firstName.isNotEmpty() || lastName.isNotEmpty()) {
                "$firstName $lastName".trim()
            } else {
                ci.from ?: ""
            }


        // Create storage instance for call parameters
        val storage: Storage = StorageImpl(applicationContext)

        // Resolve call parameters
        val callParams: TVParameters = TVCallInviteParametersImpl(storage, ci);

        // Create connection
        val connection = TVCallInviteConnection(applicationContext, ci, callParams)

        // Remove call invite from extras, causes marshalling error i.e. Class not found.
        val requestBundle = request.extras.also { it ->
            it.remove(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)
        }
        connection.extras = requestBundle

        // Setup connection event listeners and UI parameters
        attachCallEventListeners(connection, ci.callSid)
        applyParameters(connection, callParams)
         // **Override the caller display name here using the custom displayName**
            connection.setCallerDisplayName(displayName, TelecomManager.PRESENTATION_ALLOWED)
            // Optionally, if you want the address to use the displayName rather than the phone number:
            connection.setAddress(Uri.fromParts(PhoneAccount.SCHEME_TEL, displayName, null), TelecomManager.PRESENTATION_ALLOWED)

        connection.setRinging()

        startForegroundService()
        return connection
    }

    override fun onCreateOutgoingConnection(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        assert(request != null) { "ConnectionRequest cannot be null" }
        assert(connectionManagerPhoneAccount != null) { "ConnectionManagerPhoneAccount cannot be null" }

        super.onCreateOutgoingConnection(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateOutgoingConnection")

        val extras = request?.extras
        val myBundle: Bundle = extras?.getBundle(EXTRA_OUTGOING_PARAMS) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: request is missing Bundle EXTRA_OUTGOING_PARAMS")
            throw Exception("onCreateOutgoingConnection: request is missing Bundle EXTRA_OUTGOING_PARAMS");
        }

        // check required EXTRA_TOKEN, EXTRA_TO, EXTRA_FROM
        val token: String = myBundle.getString(EXTRA_TOKEN) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TOKEN")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TOKEN");
        }
        val to = myBundle.getString(EXTRA_TO) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TO")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TO");
        }
        val from = myBundle.getString(EXTRA_FROM) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_FROM")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_FROM");
        }

        // Get all params from bundle
        val params = HashMap<String, String>()
        myBundle.keySet().forEach { key ->
            when (key) {
                EXTRA_TO, EXTRA_FROM, EXTRA_TOKEN -> {}
                else -> {
                    myBundle.getString(key)?.let { value ->
                        params[key] = value
                    }
                }
            }
        }
        params["From"] = from
        params["To"] = to

        // create connect options
        val connectOptions = ConnectOptions.Builder(token)
            .params(params)
            .build()

        // create outgoing connection
        val connection = TVCallConnection(applicationContext)

        // create Voice SDK call
        connection.twilioCall = Voice.connect(applicationContext, connectOptions, connection)

        // create storage instance for call parameters
        val mStorage: Storage = StorageImpl(applicationContext)

        // Set call state listener, applies non-temporary Call SID when call is ringing or connected (i.e. when assigned by Twilio)
        val onCallStateListener: CompletionHandler<Call.State> = CompletionHandler { state ->
            if (state == Call.State.RINGING || state == Call.State.CONNECTED) {
                val call = connection.twilioCall!!
                val callSid = call.sid!!

                // Resolve call parameters
                val callParams = TVCallParametersImpl(mStorage, call, to, from, params)
                connection.setCallParameters(callParams)

                // Build custom display name for outgoing calls if provided
                val firstName = params["to_firstname"] ?: ""
                val lastName = params["to_lastname"] ?: ""
                val customDisplayName = if (firstName.isNotEmpty() || lastName.isNotEmpty()) {
                    "$firstName $lastName".trim()
                } else {
                    to
                }
                // Update the connection extras and UI parameters
                connection.extras.putString(TelecomManager.EXTRA_CALL_SUBJECT, customDisplayName)
                connection.setAddress(Uri.fromParts(PhoneAccount.SCHEME_TEL, customDisplayName, null), TelecomManager.PRESENTATION_ALLOWED)
                connection.setCallerDisplayName(customDisplayName, TelecomManager.PRESENTATION_ALLOWED)


                // If call is not attached, attach it
                if (!activeConnections.containsKey(callSid)) {
                    applyParameters(connection, callParams)
                    attachCallEventListeners(connection, callSid)
                    callParams.callSid = callSid
                }
            }
        }
        connection.setOnCallStateListener(onCallStateListener)

        // Setup connection UI parameters
        connection.setInitializing()

        // Apply extras
        connection.extras = request.extras

        startForegroundService()

        return connection
    }

    /**
     * Attach call event listeners to the given connection. This includes responding to call events, call actions and when call has ended.
     * @param connection The connection to attach the listeners to.
     * @param callSid The call SID of the connection.
     */
    private fun <T: TVCallConnection> attachCallEventListeners(connection: T, callSid: String) {

        val onAction: ValueBundleChanged<String> = ValueBundleChanged { event: String?, extra: Bundle? ->
            sendBroadcastEvent(applicationContext, event ?: "", callSid, extra)
        }

        val onEvent: ValueBundleChanged<String> = ValueBundleChanged { event: String?, extra: Bundle? ->
            sendBroadcastEvent(applicationContext, event ?: "", callSid, extra)
            // This is a temporary solution since `isOnCall` returns true when there is an active ConnectionService, regardless of the source app. This also applies to SIM/Telecom calls.
            sendBroadcastCallHandle(applicationContext, extra?.getString(TVBroadcastReceiver.EXTRA_CALL_HANDLE))
        }
        val onDisconnect: CompletionHandler<DisconnectCause> = CompletionHandler {
            dc ->
            storage.clearCustomParams()
            if (activeConnections.containsKey(callSid)) {
                activeConnections.remove(callSid)
            }

            // // ── NEW ── let your Flutter side know that the call really ended
            // if (dc?.code == DisconnectCause.LOCAL || dc?.code == DisconnectCause.REMOTE) {
            // sendBroadcastEvent(
            // applicationContext,
            // TVBroadcastReceiver.ACTION_CALL_ENDED,
            // callSid
            // )
            // }
            when (dc.code) {
                DisconnectCause.LOCAL,
                DisconnectCause.REMOTE -> sendBroadcastEvent(
                applicationContext,
                TVBroadcastReceiver.ACTION_CALL_ENDED,
                callSid
                )
                else -> Log.d(
                TAG,
                "Skipping CALL_ENDED for cause=${dc.code} (not a real hang-up)"
                )
            }

            stopForegroundService()
            stopSelfSafe()
        }

        // Add to local connection cache
        activeConnections[callSid] = connection

        // attach listeners
        connection.setOnCallActionListener(onAction)
        connection.setOnCallEventListener(onEvent)
        connection.setOnCallDisconnected(onDisconnect)
    }

    /**
     * Apply the given parameters to the given connection. This sets the address, caller display name and subject, any and all if present.
     * @param connection The connection to apply the parameters to.
     * @param params The parameters to apply to the connection.
     */
    private fun <T: TVCallConnection> applyParameters(connection: T, params: TVParameters) {
        params.getExtra(TVParameters.PARAM_SUBJECT, null)?.let {
            connection.extras.putString(TelecomManager.EXTRA_CALL_SUBJECT, it)
        }

        // val name = if(connection.callDirection == CallDirection.OUTGOING) params.to else params.from
        // connection.setAddress(Uri.fromParts(PhoneAccount.SCHEME_TEL, name, null), TelecomManager.PRESENTATION_ALLOWED)
        // connection.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
      
        // For outgoing calls, try to extract custom name from "from_firstname" and "from_lastname".
    val name = if (connection.callDirection == CallDirection.OUTGOING) {
        val firstName = params.getExtra("to_firstname", "") as? String ?: ""
        val lastName = params.getExtra("to_lastname", "") as? String ?: ""
        if (firstName.isNotEmpty() || lastName.isNotEmpty()) {
            "$firstName $lastName".trim()
        } else {
            // Fallback if custom names are not provided.
            params.to
        }
    } else {
        // For incoming calls, use the default "from" value.
        params.from
    }

    connection.setAddress(
        Uri.fromParts(PhoneAccount.SCHEME_TEL, name, null),
        TelecomManager.PRESENTATION_ALLOWED
    )
    connection.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
    }

    private fun sendBroadcastEvent(ctx: Context, event: String, callSid: String?, extras: Bundle? = null) {
        Intent(ctx, TVBroadcastReceiver::class.java).apply {
            action = event
            putExtra(EXTRA_CALL_HANDLE, callSid)
            extras?.let { putExtras(it) }
            LocalBroadcastManager.getInstance(ctx).sendBroadcast(this)
        }
    }

    private fun sendBroadcastCallHandle(ctx: Context, callSid: String?) {
        Log.d(TAG, "sendBroadcastCallHandle: ${if (callSid != null) "On call" else "Not on call"}}")
        Intent(ctx, TVBroadcastReceiver::class.java).apply {
            action = TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED
            putExtra(EXTRA_CALL_HANDLE, callSid)
            LocalBroadcastManager.getInstance(ctx).sendBroadcast(this)
        }
    }

    override fun onCreateOutgoingConnectionFailed(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?) {
        super.onCreateOutgoingConnectionFailed(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateOutgoingConnectionFailed")
        stopForegroundService()
    }

    override fun onCreateIncomingConnectionFailed(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateIncomingConnectionFailed")
        stopForegroundService()
    }

    private fun getOrCreateChannel(): NotificationChannel {
        val id = "${applicationContext.packageName}_calls"
        val name = applicationContext.appName
        val descriptionText = "Active Voice Calls"
        val importance = NotificationManager.IMPORTANCE_NONE
        val channel = NotificationChannel(id, name, importance).apply {
            description = descriptionText
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
        return channel
    }

    private fun createNotification(): Notification {
        val channel = getOrCreateChannel()

        val intent = Intent(applicationContext, TVConnectionService::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        val pendingIntent: PendingIntent = PendingIntent.getActivity(applicationContext, 0, intent, flag);

        return Notification.Builder(this, channel.id).apply {
            setOngoing(true)
            setContentTitle("Voice Calls")
            setCategory(Notification.CATEGORY_SERVICE)
            setContentIntent(pendingIntent)
            setSmallIcon(R.drawable.ic_microphone)
        }.build()
    //     val channel = getOrCreateChannel()

    // // 1) Main tap — brings you back into the service UI
    // val mainIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
    //     flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
    // }
    // val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
    //     PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    // else
    //     PendingIntent.FLAG_UPDATE_CURRENT
    // val mainPi = PendingIntent.getActivity(applicationContext, 0, mainIntent, flag)

    // // 2) Decline action — send ACTION_HANGUP with the current call’s SID
    // val activeCallHandle = getActiveCallHandle()  // may be null if no call, but safe here
    // val declineIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
    //     action = ACTION_HANGUP
    //     putExtra(EXTRA_CALL_HANDLE, activeCallHandle)
    // }
    // val declinePi = PendingIntent.getService(
    //     applicationContext,
    //     activeCallHandle?.hashCode() ?: 0,
    //     declineIntent,
    //     flag
    // )

    // return Notification.Builder(this, channel.id).apply {
    //     setOngoing(true)
    //     setContentTitle("Voice Calls")
    //     setCategory(Notification.CATEGORY_SERVICE)
    //     setContentIntent(mainPi)
    //     setSmallIcon(R.drawable.ic_microphone)

    //     // ←— here’s the new Decline button in the notification
    //     addAction(
    //         R.drawable.ic_decline,    // your decline icon
    //         "Decline",                // button label
    //         declinePi
    //     )
    // }.build()
    }

    private fun cancelNotification() {
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(SERVICE_TYPE_MICROPHONE)
    }

    /// Source: https://github.com/react-native-webrtc/react-native-callkeep/blob/master/android/src/main/java/io/wazo/callkeep/VoiceConnectionService.java#L295
    private fun startForegroundService() {
        val notification = createNotification()
        Log.d(TAG, "[VoiceConnectionService] Starting foreground service")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Optional for Android +11, required for Android +14
                startForeground(SERVICE_TYPE_MICROPHONE, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(SERVICE_TYPE_MICROPHONE, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "[VoiceConnectionService] Can't start foreground service : $e")
        }
    }

    /// Source: https://github.com/react-native-webrtc/react-native-callkeep/blob/master/android/src/main/java/io/wazo/callkeep/VoiceConnectionService.java#L352C5-L377C6
    private fun stopForegroundService() {
        Log.d(TAG, "[VoiceConnectionService] stopForegroundService")
        try {
            stopForeground(SERVICE_TYPE_MICROPHONE)
            cancelNotification()
        } catch (e: java.lang.Exception) {
            Log.w(TAG, "[VoiceConnectionService] can't stop foreground service :$e")
        }
    }
}
