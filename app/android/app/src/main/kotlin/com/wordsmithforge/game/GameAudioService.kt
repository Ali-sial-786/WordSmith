package com.wordsmithforge.game

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Keeps the game's sound going with the app in the background, shown as an
 * ongoing notification that opens the game again. MainActivity starts it in
 * one of three modes:
 * - [VOICE]: in a room's voice chat with the mic on. Android 11+ cuts the mic
 *   off for background apps unless a microphone foreground service runs, and
 *   only lets one start while the game is on screen.
 * - [LISTEN]: off screen in a voice chat with the mic off, still hearing
 *   friends.
 * - [PLAY]: off screen with the game's music and ambience playing on (the
 *   player's choice). It holds duckable audio focus meanwhile, so a phone
 *   call or another app starting to play quietens the game.
 * Android 17 silences background audio without a foreground service, and
 * Android 15 refuses audio focus to background apps without one.
 * `stopWithTask` ends it when the game is swiped away.
 */
class GameAudioService : Service() {
    private val audio by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private var focusRequest: AudioFocusRequest? = null
    private var holdingFocus = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                releaseFocus()
                onInterruption?.invoke(true, true)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> onInterruption?.invoke(true, false)
            AudioManager.AUDIOFOCUS_GAIN -> onInterruption?.invoke(false, false)
            // LOSS_TRANSIENT_CAN_DUCK (a notification, directions): Android
            // turns the game down by itself.
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mode = intent?.getIntExtra(MODE, PLAY) ?: PLAY
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
        if (mode == PLAY) holdFocus() else releaseFocus()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseFocus()
        current = NONE
        super.onDestroy()
    }

    private fun holdFocus() {
        if (holdingFocus) return
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                .build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
        }
        when (result) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> holdingFocus = true
            // A phone call is ringing or under way: quiet until it's over.
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> {
                holdingFocus = true
                onInterruption?.invoke(true, false)
            }
            // Refused: play on without hearing about other apps.
            else -> Log.w(TAG, "audio focus refused")
        }
    }

    private fun releaseFocus() {
        if (!holdingFocus) return
        holdingFocus = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
        focusRequest = null
    }

    private fun notification(mode: Int): Notification {
        val voice = mode != PLAY
        val channel = if (voice) VOICE_CHANNEL else PLAY_CHANNEL
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val (name, description) = if (voice) {
                "Voice chat" to "While you're in a room's voice chat"
            } else {
                "Playing in the background" to "While the game's music plays with Wordsmith in the background"
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(channel, name, NotificationManager.IMPORTANCE_LOW).also {
                    it.description = description
                    it.setShowBadge(false)
                },
            )
            Notification.Builder(this, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val (title, text) = when (mode) {
            VOICE -> "Voice chat on" to "Friends in your room can hear you. Tap to go back."
            LISTEN -> "Voice chat on" to "Tap to go back to your room."
            else -> "Playing in the background" to "Tap to go back to the forge."
        }
        // Like the launcher icon: back to the running game, not a new one.
        val open = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(getColor(R.color.notification_accent))
            .setContentTitle(title)
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
        const val PLAY = 3

        /** The mode the service is running in, in the foreground. */
        var current = NONE
            private set

        /**
         * In [PLAY], a call or another app took over the audio (true) or gave
         * it back (false); `forGood` when it won't be given back. Called on
         * the main thread.
         */
        var onInterruption: ((interrupted: Boolean, forGood: Boolean) -> Unit)? = null

        private const val TAG = "GameAudioService"
        private const val NOTIFICATION_ID = 7
        private const val VOICE_CHANNEL = "voice_chat"
        private const val PLAY_CHANNEL = "background_play"
    }
}
