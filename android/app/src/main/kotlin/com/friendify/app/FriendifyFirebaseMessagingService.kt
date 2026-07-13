package com.friendify.app

import android.app.ActivityManager
import android.content.Context
import android.util.Log
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService
import java.util.Collections

class FriendifyFirebaseMessagingService : FlutterFirebaseMessagingService() {
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val data = remoteMessage.data
        val type = data["type"]?.trim().orEmpty()

        if (type != "incoming_call") {
            if (isAppInForeground()) {
                logOnce("non_call_foreground", "fcm.route=foreground_flutter")
                super.onMessageReceived(remoteMessage)
            } else {
                logOnce("non_call_ignored", "fcm.non_call_native_ignored_silent")
                logOnce("non_call_bg_ignored", "fcm.duplicate_background_isolate_ignored")
            }
            return
        }

        val call = NativeCallNotificationHelper.parseIncoming(data)
        if (call == null) {
            Log.d(TAG, "NativeCallFcm: incoming_call ignored missing callId")
            return
        }

        if (isAppInForeground()) {
            Log.d(TAG, "fcm.route=foreground_flutter type=incoming_call callIdShort=${shortId(call.callId)}")
            Log.d(TAG, "native_call.foreground_flutter_preferred_no_native_notification callIdShort=${shortId(call.callId)}")
            super.onMessageReceived(remoteMessage)
            return
        }

        NativeCallNotificationHelper.createChannels(applicationContext)
        val activeCallId = NativeCallNotificationHelper.activeOngoingCallId(applicationContext)
        if (activeCallId.isNotEmpty()) {
            Log.d(
                TAG,
                "native_call.incoming_skipped_active_call " +
                    "activeCallIdShort=${shortId(activeCallId)} " +
                    "callIdShort=${shortId(call.callId)}"
            )
            NativeCallNotificationHelper.cancelIncomingCall(applicationContext, call.callId)
            return
        }

        if (!nativeNotificationPosted.add(call.callId)) {
            Log.d(TAG, "native_call.duplicate_ignored callIdShort=${shortId(call.callId)}")
            return
        }

        val route = if (MainActivity.hasStartedInProcess()) {
            "background_native"
        } else {
            "killed_native"
        }
        Log.d(TAG, "fcm.route=$route type=incoming_call callIdShort=${shortId(call.callId)}")
        NativeCallNotificationHelper.postIncomingCall(applicationContext, call)
        Log.d(TAG, "NativeCallFcm: incoming notification posted")
    }

    private fun isAppInForeground(): Boolean {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val processes = manager.runningAppProcesses ?: return false
        val packageName = packageName
        return processes.any { process ->
            process.processName == packageName &&
                process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }
    }

    private fun shortId(value: String): String {
        val safe = value.trim()
        if (safe.length <= 10) return safe
        return safe.take(6) + "..." + safe.takeLast(4)
    }

    companion object {
        private const val TAG = "NativeCallFcm"
        private val nativeNotificationPosted =
            Collections.synchronizedSet(mutableSetOf<String>())
        private val oneShotRouteLogs =
            Collections.synchronizedSet(mutableSetOf<String>())

        private fun logOnce(key: String, message: String) {
            if (oneShotRouteLogs.add(key)) {
                Log.d(TAG, message)
            }
        }
    }
}
