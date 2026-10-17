package com.wordsmithforge.game

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/** Shares downloaded updates with Android's package installer (res/xml/update_paths.xml). */
class UpdateFileProvider : FileProvider()

/**
 * Updates the game from inside it, for the `wordsmith/update` channel: downloads
 * a new version's APK into the cache (reporting "progress" back on the channel),
 * checks it really is this app at that version, and hands it to Android's
 * package installer, which asks the player to confirm. Android also needs the
 * player's leave to "install unknown apps" from the game, once.
 */
class AppUpdater(private val activity: Activity, private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private var download: Thread? = null

    @Volatile private var cancelled = false

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "download" -> download(call.argument<String>("url")!!, call.argument<String>("version")!!, result)
            "cancel" -> {
                cancelled = true
                result.success(null)
            }
            "canInstall" -> result.success(canInstall())
            "allowInstalls" -> {
                allowInstalls()
                result.success(null)
            }
            "install" -> result.success(install(File(call.arguments as String)))
            else -> result.notImplemented()
        }
    }

    private fun download(url: String, version: String, result: MethodChannel.Result) {
        if (download?.isAlive == true) {
            result.error("busy", "Already downloading", null)
            return
        }
        cancelled = false
        download = thread(name = "update-download") {
            try {
                val apk = fetch(url, version)
                main.post { result.success(apk.path) }
            } catch (e: Failure) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: IOException) {
                Log.w(TAG, "download: $e")
                main.post { result.error("network", e.toString(), null) }
            }
        }
    }

    private fun fetch(url: String, version: String): File {
        val dir = updatesDir(activity).apply { mkdirs() }
        val apk = File(dir, "wordsmith-$version.apk")
        // Already here from an earlier try (say, before allowing installs).
        if (apk.exists() && isUpdate(apk, version)) return apk
        dir.listFiles()?.forEach { it.delete() }
        val part = File(dir, "${apk.name}.part")
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
        }
        try {
            when (val code = connection.responseCode) {
                in 200..299 -> {}
                404 -> throw Failure("missing", "No APK at $url")
                else -> throw Failure("network", "HTTP $code")
            }
            val total = connection.contentLengthLong
            if (total > 0 && dir.usableSpace < total + SPARE_BYTES) throw Failure("space", "Needs $total bytes")
            var received = 0L
            var reportedAt = 0L
            connection.inputStream.use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (cancelled) throw Failure("cancelled", "Cancelled")
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        received += n
                        val now = SystemClock.elapsedRealtime()
                        if (now - reportedAt >= 200) {
                            reportedAt = now
                            progress(received, total)
                        }
                    }
                }
            }
            progress(received, total)
            if (total > 0 && received != total) throw Failure("network", "Got $received of $total bytes")
            if (!part.renameTo(apk)) throw Failure("space", "Couldn't keep the download")
            if (!isUpdate(apk, version)) {
                apk.delete()
                throw Failure("invalid", "Not Wordsmith $version")
            }
            return apk
        } catch (e: Exception) {
            part.delete()
            throw e
        } finally {
            connection.disconnect()
        }
    }

    private fun progress(received: Long, total: Long) {
        main.post { channel.invokeMethod("progress", mapOf("received" to received, "total" to total)) }
    }

    /** Whether [apk] is this app (same package) at [version]. */
    private fun isUpdate(apk: File, version: String): Boolean {
        val info = activity.packageManager.getPackageArchiveInfo(apk.path, 0) ?: return false
        return info.packageName == activity.packageName && info.versionName == version
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    /** Opens the game's "Install unknown apps" switch in Android's settings. */
    private fun allowInstalls() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
        )
    }

    /** Opens Android's installer on [apk]; false if it's gone or nothing can install it. */
    private fun install(apk: File): Boolean {
        if (!apk.exists()) return false
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "install: $e")
            false
        }
    }

    private class Failure(val code: String, message: String) : Exception(message)

    companion object {
        private const val TAG = "AppUpdater"

        /** Room to spare on top of the download, for installing it. */
        private const val SPARE_BYTES = 50L * 1024 * 1024

        private fun updatesDir(context: Context) = File(context.cacheDir, "updates")

        /** Clears out the APK of the version now installed, and half-finished downloads. */
        fun cleanUp(context: Context) {
            val installed = try {
                context.packageManager.getPackageInfo(context.packageName, 0).versionName
            } catch (e: Exception) {
                return
            }
            updatesDir(context).listFiles()?.forEach {
                if (it.name == "wordsmith-$installed.apk" || it.name.endsWith(".part")) it.delete()
            }
        }
    }
}
