package com.hiennv.flutter_callkit_incoming

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresApi
import java.util.concurrent.atomic.AtomicBoolean

@RequiresApi(Build.VERSION_CODES.M)
class InAppCallManager(private val context: Context) {

    companion object {
        private const val ACCOUNT_ID = "flutter_callkit_incoming_in_app_call_account"
        private const val TAG = "InAppCallManager"
        private val registrationLock = Any()
        private val registrationComplete = AtomicBoolean(false)
        private val duplicateSkipLogged = AtomicBoolean(false)
    }

    fun registerPhoneAccount() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val componentName = ComponentName(context, CallkitConnectionService::class.java)
        val handle = PhoneAccountHandle(componentName, ACCOUNT_ID)

        if (registrationComplete.get()) {
            logDuplicateRegistrationSkipped()
            return
        }

        synchronized(registrationLock) {
            if (registrationComplete.get()) {
                logDuplicateRegistrationSkipped()
                return
            }

            if (isPhoneAccountAlreadyRegistered(telecomManager, handle)) {
                registrationComplete.set(true)
                logDuplicateRegistrationSkipped()
                return
            }

            val phoneAccount = PhoneAccount.builder(handle, "Callkit Incoming In-App Call")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()

            telecomManager.registerPhoneAccount(phoneAccount)
            registrationComplete.set(true)
            Log.d(TAG, "PhoneAccount registered.")
        }
    }

    private fun isPhoneAccountAlreadyRegistered(
        telecomManager: TelecomManager,
        handle: PhoneAccountHandle
    ): Boolean {
        return try {
            telecomManager.getPhoneAccount(handle) != null
        } catch (_: Exception) {
            false
        }
    }

    private fun logDuplicateRegistrationSkipped() {
        if (duplicateSkipLogged.compareAndSet(false, true)) {
            Log.d(TAG, "PhoneAccount registration skipped: already registered")
        }
    }

    fun unregisterPhoneAccount() {
        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val componentName = ComponentName(context, CallkitConnectionService::class.java)
        val handle = PhoneAccountHandle(componentName, ACCOUNT_ID)

        telecomManager.unregisterPhoneAccount(handle)
        registrationComplete.set(false)
        duplicateSkipLogged.set(false)
        Log.d(TAG, "PhoneAccount unregistered.")
    }

    fun getPhoneAccountHandle(): PhoneAccountHandle {
        return PhoneAccountHandle(
            ComponentName(context, CallkitConnectionService::class.java),
            ACCOUNT_ID
        )
    }
}
