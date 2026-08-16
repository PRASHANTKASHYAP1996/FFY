package com.powerlabs.friendify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import android.util.Log

data class NativeIncomingCallData(
    val callId: String,
    val callerId: String,
    val callerName: String,
    val receiverId: String,
    val expiresAtMs: Long,
    val channelId: String
)

object NativeCallNotificationHelper {
    const val CHAT_MESSAGES_CHANNEL_ID = "chat_messages"
    const val INCOMING_CHANNEL_ID = "incoming_calls"
    const val CALLKIT_INCOMING_CHANNEL_ID = "callkit_incoming_channel_id"
    const val MISSED_CHANNEL_ID = "missed_calls"
    const val ONGOING_CHANNEL_ID = "ongoing_calls"
    private const val TAG = "NativeCall"
    private const val APP_NAME = "Friendify"
    private const val INCOMING_BASE_ID = 120000
    private const val ONGOING_BASE_ID = 130000
    private const val CALL_STATE_PREFS = "friendify_native_call_state"
    private const val KEY_ACTIVE_CALL_ID = "activeCallId"
    private const val KEY_ACTIVE_CALL_UPDATED_AT_MS = "activeCallUpdatedAtMs"
    private const val ACTIVE_CALL_GUARD_WINDOW_MS = 2L * 60L * 60L * 1000L
    private val INCOMING_VIBRATION_PATTERN = longArrayOf(0L, 450L, 250L, 450L, 250L, 700L)
    private val MISSED_VIBRATION_PATTERN = longArrayOf(0L, 220L, 160L, 220L)

    fun parseIncoming(data: Map<String, String>): NativeIncomingCallData? {
        val callId = data["callId"]?.trim().orEmpty()
        if (callId.isEmpty()) return null

        val callerName = data["callerName"]?.trim().orEmpty().ifEmpty {
            "Friendify caller"
        }

        return NativeIncomingCallData(
            callId = callId,
            callerId = data["callerId"]?.trim().orEmpty(),
            callerName = callerName,
            receiverId = (data["receiverId"] ?: data["calleeId"]).orEmpty().trim(),
            expiresAtMs = data["expiresAtMs"]?.trim()?.toLongOrNull() ?: 0L,
            channelId = data["channelId"]?.trim().orEmpty()
        )
    }

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val notificationManager = notificationManager(context)
        val ringtone = Settings.System.DEFAULT_RINGTONE_URI
        val callAudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val incoming = NotificationChannel(
            INCOMING_CHANNEL_ID,
            "Incoming calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Urgent incoming Friendify call alerts."
            enableVibration(true)
            vibrationPattern = INCOMING_VIBRATION_PATTERN
            enableLights(true)
            lightColor = Color.rgb(34, 197, 94)
            setSound(ringtone, callAudioAttributes)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val callkitIncoming = NotificationChannel(
            CALLKIT_INCOMING_CHANNEL_ID,
            "Incoming Call",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming CallKit-style Friendify call alerts."
            enableVibration(true)
            vibrationPattern = INCOMING_VIBRATION_PATTERN
            enableLights(true)
            lightColor = Color.rgb(34, 197, 94)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val missed = NotificationChannel(
            MISSED_CHANNEL_ID,
            "Missed calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Missed Friendify call alerts."
            enableVibration(true)
            vibrationPattern = MISSED_VIBRATION_PATTERN
            setSound(ringtone, callAudioAttributes)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val ongoing = NotificationChannel(
            ONGOING_CHANNEL_ID,
            "Ongoing calls",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Persistent Friendify call status."
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val chatMessages = NotificationChannel(
            CHAT_MESSAGES_CHANNEL_ID,
            "Chat messages",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Notifications for new messages in Friendify chats."
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }

        notificationManager.createNotificationChannel(chatMessages)
        notificationManager.createNotificationChannel(incoming)
        notificationManager.createNotificationChannel(callkitIncoming)
        notificationManager.createNotificationChannel(missed)
        notificationManager.createNotificationChannel(ongoing)
    }

    fun postIncomingCall(context: Context, call: NativeIncomingCallData) {
        if (call.callId.isBlank()) return
        if (isExpired(call)) {
            cancelIncomingCall(context, call.callId)
            Log.d(TAG, "NativeCallFcm: expired incoming ignored callIdShort=${shortId(call.callId)}")
            return
        }

        createChannels(context)
        val notification = buildIncomingNotification(context, call)
        try {
            notificationManager(context).notify(
                notificationTag(call.callId),
                incomingNotificationId(call.callId),
                notification
            )
            Log.d(TAG, "native_call.notification_posted callIdShort=${shortId(call.callId)}")
        } catch (securityError: SecurityException) {
            Log.d(TAG, "native_call.notification_post_failed reason=permission")
        }
    }

    fun cancelIncomingCall(context: Context, callId: String) {
        val safeCallId = callId.trim()
        if (safeCallId.isEmpty()) return
        notificationManager(context).cancel(
            notificationTag(safeCallId),
            incomingNotificationId(safeCallId)
        )
    }

    fun buildOngoingNotification(
        context: Context,
        callId: String,
        displayName: String
    ): Notification {
        createChannels(context)
        val safeCallId = callId.trim()
        val safeDisplayName = displayName.trim().ifEmpty { "Friendify call" }
        val hangUpIntent = actionPendingIntent(
            context = context,
            action = IncomingCallActionReceiver.ACTION_HANGUP_CALL,
            callId = safeCallId,
            requestOffset = 30
        )
        val openIntent = bridgeActivityPendingIntent(
            context = context,
            action = "open_call",
            callId = safeCallId,
            callerName = safeDisplayName,
            requestOffset = 31
        )

        val builder = notificationBuilder(context, ONGOING_CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Friendify call")
            .setContentText(safeDisplayName)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(safeDisplayName).build()
            builder.setStyle(Notification.CallStyle.forOngoingCall(person, hangUpIntent))
        } else {
            builder.addAction(context.applicationInfo.icon, "Hang up", hangUpIntent)
        }

        return builder.build()
    }

    fun ongoingNotificationId(callId: String): Int {
        return ONGOING_BASE_ID + stableId(callId)
    }

    fun cancelOngoingCall(context: Context, callId: String) {
        val safeCallId = callId.trim()
        if (safeCallId.isEmpty()) return
        notificationManager(context).cancel(
            notificationTag(safeCallId),
            ongoingNotificationId(safeCallId)
        )
    }

    fun activeOngoingCallId(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(
            CALL_STATE_PREFS,
            Context.MODE_PRIVATE
        )
        val activeCallId = prefs.getString(KEY_ACTIVE_CALL_ID, "")?.trim().orEmpty()
        if (activeCallId.isEmpty()) return ""

        val updatedAtMs = prefs.getLong(KEY_ACTIVE_CALL_UPDATED_AT_MS, 0L)
        val isStale = updatedAtMs <= 0L ||
            System.currentTimeMillis() - updatedAtMs > ACTIVE_CALL_GUARD_WINDOW_MS
        if (isStale) {
            prefs.edit()
                .remove(KEY_ACTIVE_CALL_ID)
                .remove(KEY_ACTIVE_CALL_UPDATED_AT_MS)
                .apply()
            return ""
        }

        return activeCallId
    }

    fun markOngoingCallActive(context: Context, callId: String) {
        val safeCallId = callId.trim()
        if (safeCallId.isEmpty()) return
        context.applicationContext.getSharedPreferences(CALL_STATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ACTIVE_CALL_ID, safeCallId)
            .putLong(KEY_ACTIVE_CALL_UPDATED_AT_MS, System.currentTimeMillis())
            .apply()
    }

    fun clearOngoingCallActive(context: Context, callId: String) {
        val safeCallId = callId.trim()
        val prefs = context.applicationContext.getSharedPreferences(
            CALL_STATE_PREFS,
            Context.MODE_PRIVATE
        )
        val activeCallId = prefs.getString(KEY_ACTIVE_CALL_ID, "")?.trim().orEmpty()
        if (activeCallId.isNotEmpty() && safeCallId.isNotEmpty() && activeCallId != safeCallId) {
            return
        }

        prefs.edit()
            .remove(KEY_ACTIVE_CALL_ID)
            .remove(KEY_ACTIVE_CALL_UPDATED_AT_MS)
            .apply()
    }

    fun fullScreenPermissionStatus(context: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return "Allowed"
        }

        return try {
            if (notificationManager(context).canUseFullScreenIntent()) {
                "Allowed"
            } else {
                "Not allowed"
            }
        } catch (_: Throwable) {
            "Unknown"
        }
    }

    private fun buildIncomingNotification(
        context: Context,
        call: NativeIncomingCallData
    ): Notification {
        val answerIntent = actionPendingIntent(
            context = context,
            action = IncomingCallActionReceiver.ACTION_ANSWER_CALL,
            callId = call.callId,
            requestOffset = 10
        )
        val rejectIntent = actionPendingIntent(
            context = context,
            action = IncomingCallActionReceiver.ACTION_REJECT_CALL,
            callId = call.callId,
            requestOffset = 20
        )
        val fullScreenIntent = bridgeActivityPendingIntent(
            context = context,
            action = "open_call",
            callId = call.callId,
            callerName = call.callerName,
            requestOffset = 40
        )
        val canUseFullScreen = canUseFullScreenIntent(context)

        val builder = notificationBuilder(context, INCOMING_CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(call.callerName)
            .setContentText("Incoming Friendify call")
            .setContentIntent(fullScreenIntent)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(false)
            .setAutoCancel(false)
            .setPriority(Notification.PRIORITY_MAX)
            .setDefaults(Notification.DEFAULT_ALL)
            .setVibrate(INCOMING_VIBRATION_PATTERN)
            .setColor(Color.rgb(34, 197, 94))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && call.expiresAtMs > 0L) {
            val timeoutMs = call.expiresAtMs - System.currentTimeMillis()
            if (timeoutMs > 0L) builder.setTimeoutAfter(timeoutMs)
        }

        if (canUseFullScreen) {
            builder.setFullScreenIntent(fullScreenIntent, true)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(call.callerName).build()
            builder.setStyle(
                Notification.CallStyle.forIncomingCall(
                    person,
                    rejectIntent,
                    answerIntent
                )
            )
        } else {
            builder
                .addAction(context.applicationInfo.icon, "Reject", rejectIntent)
                .addAction(context.applicationInfo.icon, "Answer", answerIntent)
        }

        return builder.build()
    }

    private fun notificationBuilder(context: Context, channelId: String): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
    }

    private fun actionPendingIntent(
        context: Context,
        action: String,
        callId: String,
        requestOffset: Int
    ): PendingIntent {
        val intent = Intent(context, IncomingCallActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_FRIENDIFY_ACTION, actionToBridgeAction(action))
            putExtra(MainActivity.EXTRA_CALL_ID, callId)
            putExtra(MainActivity.EXTRA_SOURCE, "native_notification")
        }
        return PendingIntent.getActivity(
            context,
            requestCode(callId, requestOffset),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun bridgeActivityPendingIntent(
        context: Context,
        action: String,
        callId: String,
        callerName: String,
        requestOffset: Int
    ): PendingIntent {
        val intent = Intent(context, IncomingCallActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_FRIENDIFY_ACTION, action)
            putExtra(MainActivity.EXTRA_CALL_ID, callId)
            putExtra(MainActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(MainActivity.EXTRA_SOURCE, "native_notification")
        }
        return PendingIntent.getActivity(
            context,
            requestCode(callId, requestOffset),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun actionToBridgeAction(action: String): String {
        return when (action) {
            IncomingCallActionReceiver.ACTION_ANSWER_CALL -> "answer_call"
            IncomingCallActionReceiver.ACTION_REJECT_CALL -> "reject_call"
            IncomingCallActionReceiver.ACTION_HANGUP_CALL -> "hangup_call"
            else -> "open_call"
        }
    }

    private fun isExpired(call: NativeIncomingCallData): Boolean {
        return call.expiresAtMs > 0L && call.expiresAtMs <= System.currentTimeMillis()
    }

    private fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        return try {
            notificationManager(context).canUseFullScreenIntent()
        } catch (_: Throwable) {
            false
        }
    }

    private fun notificationManager(context: Context): NotificationManager {
        return context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    private fun incomingNotificationId(callId: String): Int {
        return INCOMING_BASE_ID + stableId(callId)
    }

    private fun notificationTag(callId: String): String {
        return "friendify_call_${shortId(callId)}"
    }

    private fun requestCode(callId: String, offset: Int): Int {
        return offset * 100000 + stableId(callId)
    }

    private fun stableId(callId: String): Int {
        return callId.hashCode().and(0x0fffffff)
    }

    private fun shortId(value: String): String {
        val safe = value.trim()
        if (safe.length <= 10) return safe
        return safe.take(6) + "..." + safe.takeLast(4)
    }
}
