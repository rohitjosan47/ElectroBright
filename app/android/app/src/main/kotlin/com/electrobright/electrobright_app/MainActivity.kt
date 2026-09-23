package com.electrobright.electrobright_app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var platformHost: PlatformHost? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val platform = PlatformHost(this)
        PlatformHostApi.setUp(messenger, platform)
        HapticsHostApi.setUp(messenger, HapticsHost(this))
        platformHost = platform
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DisplayRefresh.preferHighestRefreshRate(this)
    }

    override fun onResume() {
        super.onResume()
        DisplayRefresh.preferHighestRefreshRate(this)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        platformHost?.onRequestPermissionsResult(requestCode)
    }

    @Deprecated("FlutterActivity is not a ComponentActivity; the result API is unavailable")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        platformHost?.onActivityResult(requestCode, resultCode)
    }
}
