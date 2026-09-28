package com.electrobright.electrobright_app

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import kotlinx.coroutines.CompletableDeferred

/**
 * Native services for Dart (pigeons/platform_api.dart): Bluetooth permission
 * without touching the BLE plugin, Bluetooth/location switches, settings links.
 */
class PlatformHost(private val activity: Activity) : PlatformHostApi {
    private val prefs = activity.getSharedPreferences("electrobright_native", Context.MODE_PRIVATE)
    private var permissionRequest: CompletableDeferred<BluetoothAuthorization>? = null
    private var enableRequest: CompletableDeferred<Boolean>? = null

    private val requiredPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    override fun bluetoothAuthorization(): BluetoothAuthorization {
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return BluetoothAuthorization.UNSUPPORTED
        }
        if (requiredPermissions.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
            return BluetoothAuthorization.ALLOWED
        }
        // Android cannot tell "never asked" from "denied"; remember whether we asked.
        return if (prefs.getBoolean(KEY_ASKED, false)) BluetoothAuthorization.DENIED
        else BluetoothAuthorization.NOT_DETERMINED
    }

    override suspend fun requestBluetoothAuthorization(): BluetoothAuthorization {
        val current = bluetoothAuthorization()
        if (current == BluetoothAuthorization.ALLOWED || current == BluetoothAuthorization.UNSUPPORTED) {
            return current
        }
        // After "don't ask again" Android answers immediately without UI; Dart then offers Settings.
        permissionRequest?.cancel()
        val request = CompletableDeferred<BluetoothAuthorization>()
        permissionRequest = request
        prefs.edit().putBoolean(KEY_ASKED, true).apply()
        activity.requestPermissions(requiredPermissions, REQUEST_PERMISSIONS)
        return request.await()
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST_PERMISSIONS) return
        permissionRequest?.complete(bluetoothAuthorization())
        permissionRequest = null
    }

    override suspend fun requestEnableBluetooth(): Boolean {
        val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            ?: return false
        if (adapter.isEnabled) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        enableRequest?.cancel()
        val request = CompletableDeferred<Boolean>()
        enableRequest = request
        @Suppress("DEPRECATION")
        activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), REQUEST_ENABLE_BLUETOOTH)
        return request.await()
    }

    fun onActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode != REQUEST_ENABLE_BLUETOOTH) return
        enableRequest?.complete(resultCode == Activity.RESULT_OK)
        enableRequest = null
    }

    override fun locationServicesRequiredButOff(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return false
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(activity.contentResolver, Settings.Secure.LOCATION_MODE, Settings.Secure.LOCATION_MODE_OFF) !=
                Settings.Secure.LOCATION_MODE_OFF
        }
        return !enabled
    }

    override fun openSettings(page: SettingsPage) {
        val intent = when (page) {
            SettingsPage.APP -> Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null),
            )
            SettingsPage.BLUETOOTH -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            SettingsPage.LOCATION -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
        }
        activity.startActivity(intent)
    }

    override fun reduceTransparency(): Boolean = false

    override fun beginBackgroundTask(name: String): Long = -1

    override fun endBackgroundTask(id: Long) {}

    override fun displayInfo(): DisplayInfo {
        val (current, max) = DisplayRefresh.rates(activity)
        return DisplayInfo(refreshRate = current, maxRefreshRate = max)
    }

    override fun setHighRefreshRate(high: Boolean) {
        DisplayRefresh.setHigh(activity, high)
    }

    // A firmware transfer keeps the screen on.
    override fun setKeepAwake(on: Boolean) {
        activity.runOnUiThread {
            if (on) {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private companion object {
        const val REQUEST_PERMISSIONS = 0xEB01
        const val REQUEST_ENABLE_BLUETOOTH = 0xEB02
        const val KEY_ASKED = "bluetooth_permission_asked"
    }
}
