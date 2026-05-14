package co.enspyr.recycledsound

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "co.enspyr.recycledSound/device_telemetry"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "snapshot" -> result.success(snapshot())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Mirrors the iOS payload so Dart can consume one shape.
     */
    private fun snapshot(): Map<String, Any?> {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager

        val (thermalState, thermalLoad) = thermalReading(pm)
        val battery = batteryReading()

        return mapOf(
            "thermalState" to thermalState,
            "thermalLoad" to thermalLoad,
            "thermalHeadroom" to thermalHeadroom(pm),
            "lowPowerMode" to pm.isPowerSaveMode,
            "processorCount" to Runtime.getRuntime().availableProcessors(),
            "activeProcessorCount" to Runtime.getRuntime().availableProcessors(),
            "physicalMemoryBytes" to physicalMemoryBytes(),
            "physicalMemoryGB" to physicalMemoryBytes() / 1_073_741_824.0,
            "uptime" to (android.os.SystemClock.elapsedRealtime() / 1000.0),
            "hasLidar" to false,
            // Android exposes no honest NPU probe — NNAPI presence (API 27+)
            // doesn't imply hardware acceleration; the API silently falls
            // back to CPU on devices without an NPU. Returning null lets the
            // Dart UI omit the row rather than render a confident lie.
            "hasNeuralEngine" to null,
            "batteryTemperatureC" to battery.first,
            "batteryVoltageMv" to battery.second,
            "socModel" to (if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else null),
        )
    }

    /** Android's PowerManager.getCurrentThermalStatus is API 29+. */
    private fun thermalReading(pm: PowerManager): Pair<String, Double> {
        if (Build.VERSION.SDK_INT < 29) return "unknown" to 0.0
        return when (pm.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal" to 0.10
            PowerManager.THERMAL_STATUS_LIGHT -> "fair" to 0.30
            PowerManager.THERMAL_STATUS_MODERATE -> "fair" to 0.50
            PowerManager.THERMAL_STATUS_SEVERE -> "serious" to 0.75
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical" to 0.90
            PowerManager.THERMAL_STATUS_EMERGENCY -> "critical" to 0.97
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical" to 1.0
            else -> "unknown" to 0.0
        }
    }

    /** Predictive headroom — API 30+. Null where unsupported. */
    private fun thermalHeadroom(pm: PowerManager): Double? {
        if (Build.VERSION.SDK_INT < 30) return null
        val v = pm.getThermalHeadroom(0)
        return if (v.isNaN()) null else v.toDouble()
    }

    /** Battery temperature (°C) and voltage (mV) via the sticky battery intent. */
    private fun batteryReading(): Pair<Double?, Int?> {
        val intent: Intent? = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val tempTenths = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        val voltage = intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1
        return (if (tempTenths > 0) tempTenths / 10.0 else null) to (if (voltage > 0) voltage else null)
    }

    private fun physicalMemoryBytes(): Long {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val mi = android.app.ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        return mi.totalMem
    }
}
