package io.github.itskavin.deckos

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val DEVICE_INFO_CHANNEL = "deckos/device_info"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getDeviceInfo") {
                    // Only coarse hardware labels; never send serial, ANDROID_ID, IMEI, or user data.
                    result.success(
                        mapOf(
                            "manufacturer" to (Build.MANUFACTURER ?: ""),
                            "model" to (Build.MODEL ?: ""),
                        )
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
}
