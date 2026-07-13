package com.friendify.app

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager

class IncomingCallActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prepareLockedScreenWindow()

        val callId = intent.getStringExtra(MainActivity.EXTRA_CALL_ID)?.trim().orEmpty()
        val action = intent.getStringExtra(MainActivity.EXTRA_FRIENDIFY_ACTION)?.trim()
            ?.ifEmpty { "open_call" } ?: "open_call"
        val source = intent.getStringExtra(MainActivity.EXTRA_SOURCE)?.trim()
            ?.ifEmpty { "native_full_screen" } ?: "native_full_screen"
        if (callId.isNotEmpty()) {
            handleLocalNotificationSideEffects(action, callId)
            MainActivity.openWithNativeCallAction(
                context = this,
                action = action,
                callId = callId,
                source = source
            )
        } else {
            startActivity(Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            })
        }
        finish()
    }

    private fun prepareLockedScreenWindow() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    private fun handleLocalNotificationSideEffects(action: String, callId: String) {
        when (action) {
            "answer_call" -> {
                NativeCallNotificationHelper.cancelIncomingCall(this, callId)
                Log.d(TAG, "native_call.action_received action=answer_call callIdShort=${shortId(callId)}")
            }

            "reject_call" -> {
                NativeCallNotificationHelper.cancelIncomingCall(this, callId)
                Log.d(TAG, "native_call.action_received action=reject_call callIdShort=${shortId(callId)}")
            }

            "hangup_call" -> {
                Log.d(TAG, "native_call.action_received action=hangup_call callIdShort=${shortId(callId)}")
            }
        }
    }

    private fun shortId(value: String): String {
        val safe = value.trim()
        if (safe.length <= 10) return safe
        return safe.take(6) + "..." + safe.takeLast(4)
    }

    companion object {
        private const val TAG = "NativeCallActivity"
    }
}
