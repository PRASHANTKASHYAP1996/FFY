package com.friendify.app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

class OngoingCallService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action.orEmpty()
        val callId = intent?.getStringExtra(MainActivity.EXTRA_CALL_ID)?.trim().orEmpty()

        if (action == ACTION_STOP || callId.isEmpty()) {
            NativeCallNotificationHelper.clearOngoingCallActive(this, callId)
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val displayName = intent?.getStringExtra(EXTRA_DISPLAY_NAME)?.trim().orEmpty()
        val notification = NativeCallNotificationHelper.buildOngoingNotification(
            context = this,
            callId = callId,
            displayName = displayName
        )
        val notificationId = NativeCallNotificationHelper.ongoingNotificationId(callId)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    notificationId,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                )
            } else {
                startForeground(notificationId, notification)
            }

            NativeCallNotificationHelper.markOngoingCallActive(this, callId)
            NativeCallNotificationHelper.cancelIncomingCall(this, callId)
            Log.d(TAG, "native_call.ongoing_started callIdShort=${shortId(callId)}")
            return START_STICKY
        } catch (error: Throwable) {
            Log.d(
                TAG,
                "native_call.ongoing_start_failed callIdShort=${shortId(callId)}"
            )
            stopSelf()
            return START_NOT_STICKY
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "native_call.ongoing_stopped")
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun shortId(value: String): String {
        val safe = value.trim()
        if (safe.length <= 10) return safe
        return safe.take(6) + "..." + safe.takeLast(4)
    }

    companion object {
        private const val TAG = "NativeCallOngoing"
        private const val ACTION_START = "com.friendify.app.ACTION_START_ONGOING_CALL"
        private const val ACTION_STOP = "com.friendify.app.ACTION_STOP_ONGOING_CALL"
        private const val EXTRA_DISPLAY_NAME = "displayName"

        fun start(context: Context, callId: String, displayName: String): Boolean {
            val safeCallId = callId.trim()
            if (safeCallId.isEmpty()) return false

            val intent = Intent(context, OngoingCallService::class.java).apply {
                action = ACTION_START
                putExtra(MainActivity.EXTRA_CALL_ID, safeCallId)
                putExtra(EXTRA_DISPLAY_NAME, displayName)
            }

            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (error: Throwable) {
                Log.d(
                    TAG,
                    "native_call.ongoing_start_failed callIdShort=${shortId(safeCallId)}"
                )
                false
            }
        }

        fun stop(context: Context, callId: String): Boolean {
            val safeCallId = callId.trim()
            if (safeCallId.isNotEmpty()) {
                NativeCallNotificationHelper.cancelOngoingCall(context, safeCallId)
                NativeCallNotificationHelper.clearOngoingCallActive(context, safeCallId)
            }

            val intent = Intent(context, OngoingCallService::class.java).apply {
                action = ACTION_STOP
                putExtra(MainActivity.EXTRA_CALL_ID, safeCallId)
            }
            return try {
                context.startService(intent)
                true
            } catch (error: Throwable) {
                false
            }
        }

        private fun shortId(value: String): String {
            val safe = value.trim()
            if (safe.length <= 10) return safe
            return safe.take(6) + "..." + safe.takeLast(4)
        }
    }
}
