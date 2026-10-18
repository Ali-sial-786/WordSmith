package com.wordsmithforge.game

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps a room's voice chat going with the app in the background, shown as
 * an ongoing notification that opens the game again. (The game's music and
 * ambience pause off screen.) MainActivity starts it in one of two modes:
 * - [VOICE]: in a room's voice chat with the mic on. Android 11+ cuts the mic
 *   off for background apps unless a microphone foreground service runs, and
 *   only lets one start while the game is on screen.
 * - [LISTEN]: off screen in a voice chat with the mic off, still hearing
 *   friends. Android 17 silences background audio without a foreground
 *   service.
 * `stopWithTask` ends it when the game is swiped away.
 */
class GameAudioService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mode = intent?.getIntExtra(MODE, LISTEN) ?: LISTEN
        try {
            val notification = notification(mode)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = if (mode == VOICE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                }
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Not allowed right now (the game left the screen first, or the
            // mic permission is missing): the sound goes on without it.
            Log.w(TAG, "can't run in the foreground: $e")
            current = NONE
            stopSelf()
            return START_NOT_STICKY
        }
        current = mode
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        current = NONE
        super.onDestroy()
    }

    private fun notification(mode: Int): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(VOICE_CHANNEL, "Voice chat", NotificationManager.IMPORTANCE_LOW).also {
                    it.description = "While you're in a room's voice chat"
                    it.setShowBadge(false)
                },
            )
            // A channel left from versions that played music in the background.
            getSystemService(NotificationManager::class.java).deleteNotificationChannel("background_play")
            Notification.Builder(this, VOICE_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val text = if (mode == VOICE) "Friends in your room can hear you. Tap to go back." else "Tap to go back to your room."

        // Like the launcher icon: back to the running game, not a new one.
        val open = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(getColor(R.color.notification_accent))
            .setContentTitle("Voice chat on")
            .setContentText(text)
            .setContentIntent(
                PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        const val MODE = "mode"
        const val NONE = 0
        const val VOICE = 1
        const val LISTEN = 2

        /** The mode the service is running in, in the foreground. */
        var current = NONE
            private set

        private const val TAG = "GameAudioService"
        private const val NOTIFICATION_ID = 7
        private const val VOICE_CHANNEL = "voice_chat"
    }
}
