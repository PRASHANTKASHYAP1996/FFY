package com.powerx.friendify

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activityStartedInProcess = true
        storeNativeCallActionFromIntent(intent)
        deliverPendingActions(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        storeNativeCallActionFromIntent(intent)
        deliverPendingActions(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeBridgeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_BRIDGE_CHANNEL
        ).apply {
            setMethodCallHandler(::handleNativeBridgeCall)
        }
        deliverPendingActions(this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nativeBridgeChannel?.setMethodCallHandler(null)
        nativeBridgeChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun handleNativeBridgeCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumePendingNativeCallActions" -> result.success(consumePendingActions(this))
            "getFullScreenCallPermissionStatus" -> {
                result.success(NativeCallNotificationHelper.fullScreenPermissionStatus(this))
            }
            "startOngoingCallNotification" -> {
                val args = mapFrom(call.arguments)
                val callId = args[EXTRA_CALL_ID]?.toString()?.trim().orEmpty()
                val displayName = args["displayName"]?.toString()?.trim().orEmpty()
                if (callId.isNotEmpty()) {
                    result.success(OngoingCallService.start(this, callId, displayName))
                } else {
                    result.success(false)
                }
            }
            "stopOngoingCallNotification" -> {
                val args = mapFrom(call.arguments)
                val callId = args[EXTRA_CALL_ID]?.toString()?.trim().orEmpty()
                result.success(OngoingCallService.stop(this, callId))
            }
            "cancelIncomingCallNotification" -> {
                val args = mapFrom(call.arguments)
                val callId = args[EXTRA_CALL_ID]?.toString()?.trim().orEmpty()
                if (callId.isNotEmpty()) {
                    NativeCallNotificationHelper.cancelIncomingCall(this, callId)
                }
                result.success(true)
            }
            "setCallKeepScreenOn" -> {
                val args = mapFrom(call.arguments)
                val enabled = args["enabled"] as? Boolean ?: false
                val owner = args["owner"]?.toString()?.trim().orEmpty().ifEmpty { "call" }
                runOnUiThread {
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        Log.d(TAG, "call_wake_lock.enabled owner=$owner")
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        Log.d(TAG, "call_wake_lock.released owner=$owner")
                    }
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun storeNativeCallActionFromIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.getStringExtra(EXTRA_FRIENDIFY_ACTION)?.trim().orEmpty()
        val callId = intent.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        val source = intent.getStringExtra(EXTRA_SOURCE)?.trim().orEmpty()

        if (action.isEmpty() || callId.isEmpty()) return
        storePendingAction(this, action, callId, source.ifEmpty { "native_intent" })
    }

    companion object {
        const val EXTRA_FRIENDIFY_ACTION = "friendify_action"
        const val EXTRA_CALL_ID = "callId"
        const val EXTRA_CALLER_NAME = "callerName"
        const val EXTRA_SOURCE = "source"

        private const val TAG = "NativeCallBridge"
        private const val NATIVE_BRIDGE_CHANNEL = "friendify/native_call_bridge"
        private const val NATIVE_ACTION_PREFS = "friendify_native_call_actions"
        private const val KEY_PENDING_ACTIONS = "pendingActions"
        private const val KEY_STORED_AT_MS = "storedAtMs"
        private const val PENDING_ACTION_RETENTION_MS = 2L * 60L * 1000L

        private val pendingActions = LinkedHashMap<String, HashMap<String, String>>()
        private val deliveredActionKeys = LinkedHashSet<String>()
        private var nativeBridgeChannel: MethodChannel? = null
        private var activityStartedInProcess = false

        fun hasStartedInProcess(): Boolean = activityStartedInProcess

        fun openWithNativeCallAction(
            context: Context,
            action: String,
            callId: String,
            source: String
        ) {
            val safeAction = action.trim()
            val safeCallId = callId.trim()
            if (safeAction.isEmpty() || safeCallId.isEmpty()) return

            val stored = storePendingAction(
                context.applicationContext,
                safeAction,
                safeCallId,
                source.trim().ifEmpty { "native_notification" }
            )
            if (!stored) return

            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
                putExtra(EXTRA_FRIENDIFY_ACTION, safeAction)
                putExtra(EXTRA_CALL_ID, safeCallId)
                putExtra(EXTRA_SOURCE, source.trim().ifEmpty { "native_notification" })
            }
            context.startActivity(intent)
            deliverPendingActions(context.applicationContext)
        }

        private fun storePendingAction(
            context: Context?,
            action: String,
            callId: String,
            source: String
        ): Boolean {
            loadPersistedPendingActions(context)
            val key = actionKey(action, callId)
            if (deliveredActionKeys.contains(key)) {
                Log.d(TAG, "native_call.action_duplicate_ignored callIdShort=${shortId(callId)}")
                return false
            }
            if (pendingActions.containsKey(key)) {
                Log.d(TAG, "native_call.action_duplicate_ignored callIdShort=${shortId(callId)}")
                return false
            }

            pendingActions[key] = hashMapOf(
                "action" to action,
                EXTRA_CALL_ID to callId,
                EXTRA_SOURCE to source,
                KEY_STORED_AT_MS to System.currentTimeMillis().toString()
            )
            persistPendingActions(context)
            Log.d(TAG, "native_call.action_pending_stored callIdShort=${shortId(callId)}")
            return true
        }

        private fun deliverPendingActions(context: Context?) {
            val channel = nativeBridgeChannel ?: return
            loadPersistedPendingActions(context)
            val actions = pendingActions.values.toList()
            for (action in actions) {
                val actionName = action["action"].orEmpty()
                val callId = action[EXTRA_CALL_ID].orEmpty()
                val key = actionKey(actionName, callId)
                channel.invokeMethod(
                    "nativeCallAction",
                    action,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            removePendingAction(context, key)
                            deliveredActionKeys.add(key)
                            Log.d(
                                TAG,
                                "native_call.action_delivered_once callIdShort=${shortId(callId)}"
                            )
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            Log.d(
                                TAG,
                                "NativeCallBridge: action delivery deferred callIdShort=${shortId(callId)}"
                            )
                        }

                        override fun notImplemented() {
                            Log.d(
                                TAG,
                                "NativeCallBridge: action delivery not implemented callIdShort=${shortId(callId)}"
                            )
                        }
                    }
                )
            }
        }

        private fun consumePendingActions(context: Context?): List<Map<String, String>> {
            loadPersistedPendingActions(context)
            val actions = pendingActions.values.map { HashMap(it) }
            for (action in actions) {
                val actionName = action["action"].orEmpty()
                val callId = action[EXTRA_CALL_ID].orEmpty()
                deliveredActionKeys.add(actionKey(actionName, callId))
                Log.d(TAG, "native_call.action_delivered_once callIdShort=${shortId(callId)}")
            }
            pendingActions.clear()
            persistPendingActions(context)
            return actions
        }

        private fun removePendingAction(context: Context?, key: String) {
            pendingActions.remove(key)
            persistPendingActions(context)
        }

        private fun loadPersistedPendingActions(context: Context?) {
            val prefsContext = context?.applicationContext ?: return
            val raw = prefsContext.getSharedPreferences(NATIVE_ACTION_PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PENDING_ACTIONS, "[]")
                .orEmpty()
            if (raw.isBlank()) return

            var changed = false
            try {
                val now = System.currentTimeMillis()
                val actions = JSONArray(raw)
                for (index in 0 until actions.length()) {
                    val item = actions.optJSONObject(index) ?: continue
                    val action = item.optString("action").trim()
                    val callId = item.optString(EXTRA_CALL_ID).trim()
                    val source = item.optString(EXTRA_SOURCE).trim().ifEmpty {
                        "native_notification"
                    }
                    val storedAtMs = item.optLong(KEY_STORED_AT_MS, 0L)
                    if (action.isEmpty() || callId.isEmpty()) {
                        changed = true
                        continue
                    }
                    if (storedAtMs <= 0L || now - storedAtMs > PENDING_ACTION_RETENTION_MS) {
                        changed = true
                        continue
                    }

                    val key = actionKey(action, callId)
                    if (deliveredActionKeys.contains(key) || pendingActions.containsKey(key)) {
                        continue
                    }
                    pendingActions[key] = hashMapOf(
                        "action" to action,
                        EXTRA_CALL_ID to callId,
                        EXTRA_SOURCE to source,
                        KEY_STORED_AT_MS to storedAtMs.toString()
                    )
                }
            } catch (_: Throwable) {
                pendingActions.clear()
                changed = true
            }

            if (changed) persistPendingActions(prefsContext)
        }

        private fun persistPendingActions(context: Context?) {
            val prefsContext = context?.applicationContext ?: return
            val actions = JSONArray()
            pendingActions.values.forEach { action ->
                actions.put(JSONObject().apply {
                    put("action", action["action"].orEmpty())
                    put(EXTRA_CALL_ID, action[EXTRA_CALL_ID].orEmpty())
                    put(EXTRA_SOURCE, action[EXTRA_SOURCE].orEmpty())
                    put(KEY_STORED_AT_MS, action[KEY_STORED_AT_MS].orEmpty())
                })
            }
            prefsContext.getSharedPreferences(NATIVE_ACTION_PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_PENDING_ACTIONS, actions.toString())
                .apply()
        }

        private fun actionKey(action: String, callId: String): String {
            return "${action.trim()}::${callId.trim()}"
        }

        private fun mapFrom(value: Any?): Map<String, Any?> {
            if (value !is Map<*, *>) return emptyMap()
            return value.entries.associate { entry ->
                entry.key.toString() to entry.value
            }
        }

        private fun shortId(value: String): String {
            val safe = value.trim()
            if (safe.length <= 10) return safe
            return safe.take(6) + "..." + safe.takeLast(4)
        }
    }
}
