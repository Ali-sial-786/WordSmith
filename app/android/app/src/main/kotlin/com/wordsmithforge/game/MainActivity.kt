package com.wordsmithforge.game

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val prefs by lazy { getSharedPreferences("wordsmith_native", Context.MODE_PRIVATE) }

    /** The renderer this launch uses: "vulkan" (Impeller's default) or "opengles". */
    private var backend = "vulkan"

    // Called once, before the engine starts, so it can pick the renderer.
    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = super.getFlutterShellArgs()
        noteCrashes()
        backend = if (prefs.getBoolean(COMPAT, false)) "opengles" else "vulkan"
        if (backend == "opengles") args.add("--impeller-backend=opengles")
        prefs.edit().putString(BACKEND, backend).apply()
        return args
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wordsmith/diagnostics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "device" -> result.success(
                        "${Build.MANUFACTURER} ${Build.MODEL} (Android ${Build.VERSION.RELEASE}, API ${Build.VERSION.SDK_INT})",
                    )
                    "lastCrash" -> result.success(prefs.getString(LAST_CRASH, null))
                    "graphics" -> result.success(
                        mapOf(
                            "compat" to prefs.getBoolean(COMPAT, false),
                            "auto" to prefs.getBoolean(COMPAT_AUTO, false),
                            "active" to backend,
                        ),
                    )
                    "setCompat" -> {
                        prefs.edit()
                            .putBoolean(COMPAT, call.arguments == true)
                            .putBoolean(COMPAT_AUTO, false)
                            .apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Looks at how the app stopped since the last launch (Android 11+). A
     * crash is kept as the "last crash" report, and a native crash on Vulkan
     * turns on compatibility graphics (OpenGL ES), since that is most often
     * the GPU driver.
     */
    private fun noteCrashes() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val seen = prefs.getLong(SEEN_EXIT_AT, 0)
        val exits = try {
            (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                .getHistoricalProcessExitReasons(packageName, 0, 8)
        } catch (e: Exception) {
            return
        }
        val fresh = exits.filter { it.timestamp > seen }
        if (fresh.isEmpty()) return
        val edit = prefs.edit().putLong(SEEN_EXIT_AT, fresh.maxOf { it.timestamp })
        val crash = fresh.filter { kindOf(it) != null }.maxByOrNull { it.timestamp }
        if (crash != null) {
            val lastBackend = prefs.getString(BACKEND, "vulkan")
            edit.putString(LAST_CRASH, report(crash, lastBackend).toString())
            if (crash.reason == ApplicationExitInfo.REASON_CRASH_NATIVE &&
                lastBackend == "vulkan" &&
                !prefs.getBoolean(COMPAT, false)
            ) {
                edit.putBoolean(COMPAT, true).putBoolean(COMPAT_AUTO, true)
            }
        }
        edit.apply()
    }

    private fun kindOf(info: ApplicationExitInfo): String? = when (info.reason) {
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "init_failure"
        else -> null
    }

    private fun report(info: ApplicationExitInfo, lastBackend: String?): JSONObject {
        val trace = try {
            info.traceInputStream?.use { s ->
                val bytes = s.readBytes()
                // ANR traces are text; native tombstones are protobuf, whose
                // readable parts (signal, abort message, backtrace) are enough.
                if (info.reason == ApplicationExitInfo.REASON_ANR) {
                    String(bytes, Charsets.UTF_8).take(MAX_TRACE)
                } else {
                    printable(bytes)
                }
            }
        } catch (e: Exception) {
            null
        }
        return JSONObject()
            .put("kind", kindOf(info))
            .put("at", info.timestamp)
            .put("description", info.description ?: "")
            .put("status", info.status)
            .put("pssKb", info.pss)
            .put("rssKb", info.rss)
            .put("backend", lastBackend ?: "vulkan")
            .put("trace", trace ?: "")
    }

    /** The runs of 6 or more printable characters in [bytes], one per line. */
    private fun printable(bytes: ByteArray): String {
        val out = StringBuilder()
        val run = StringBuilder()
        for (b in bytes) {
            val c = b.toInt() and 0xff
            if (c in 0x20..0x7e) {
                run.append(c.toChar())
                continue
            }
            if (run.length >= 6) out.append(run).append('\n')
            run.setLength(0)
            if (out.length >= MAX_TRACE) break
        }
        if (run.length >= 6) out.append(run)
        return out.toString().take(MAX_TRACE)
    }

    private companion object {
        const val COMPAT = "compatGraphics"
        const val COMPAT_AUTO = "compatGraphicsAuto"
        const val BACKEND = "backend"
        const val SEEN_EXIT_AT = "seenExitAt"
        const val LAST_CRASH = "lastCrash"
        const val MAX_TRACE = 12_000
    }
}
