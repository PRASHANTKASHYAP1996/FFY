package com.friendify.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class IncomingCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(MainActivity.EXTRA_CALL_ID)?.trim().orEmpty()
        if (callId.isEmpty()) return

        when (intent.action) {
            ACTION_ANSWER_CALL -> {
                NativeCallNotificationHelper.cancelIncomingCall(context, callId)
                Log.d(TAG, "native_call.action_received action=answer_call callIdShort=${shortId(callId)}")
                MainActivity.openWithNativeCallAction(
                    context = context,
                    action = "answer_call",
                    callId = callId,
                    source = "native_notification"
                )
            }

            ACTION_REJECT_CALL -> {
                NativeCallNotificationHelper.cancelIncomingCall(context, callId)
                Log.d(TAG, "native_call.action_received action=reject_call callIdShort=${shortId(callId)}")
                MainActivity.openWithNativeCallAction(
                    context = context,
                    action = "reject_call",
                    callId = callId,
                    source = "native_notification"
                )
            }

            ACTION_HANGUP_CALL -> {
                Log.d(TAG, "native_call.action_received action=hangup_call callIdShort=${shortId(callId)}")
                MainActivity.openWithNativeCallAction(
                    context = context,
                    action = "hangup_call",
                    callId = callId,
                    source = "native_ongoing_notification"
                )
            }
        }
    }

    private fun shortId(value: String): String {
        val safe = value.trim()
        if (safe.length <= 10) return safe
        return safe.take(6) + "..." + safe.takeLast(4)
    }

    companion object {
        const val ACTION_ANSWER_CALL = "com.friendify.app.ACTION_ANSWER_CALL"
        const val ACTION_REJECT_CALL = "com.friendify.app.ACTION_REJECT_CALL"
        const val ACTION_HANGUP_CALL = "com.friendify.app.ACTION_HANGUP_CALL"
        private const val TAG = "NativeCallAction"
    }
}
