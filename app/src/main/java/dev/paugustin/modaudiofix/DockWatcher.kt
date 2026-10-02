package dev.paugustin.modaudiofix

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log

private const val TAG = "ModAudioFix"
private const val CHECK_INTERVAL_MS = 3000L

// The mod is connected as AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET: TYPE_DOCK_ANALOG
// since Android 14, TYPE_DOCK before.

/**
 * Keeps force_use(FOR_DOCK) at ANALOG_DOCK while the mod's dock device is connected.
 *
 * AudioService resets FOR_DOCK to FORCE_DIGITAL_DOCK in readDockAudioSettings()
 * (on every user switch, e.g. moving to a child's profile) and in
 * onAudioServerDied(). A one-shot setForceUse() on mod attach is therefore not
 * enough: this watcher runs in the persistent app process and puts the value
 * back whenever it changes.
 */
class DockWatcher(context: Context) {

    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val thread = HandlerThread("DockWatcher").apply { start() }
    private val handler = Handler(thread.looper)

    @Volatile
    private var dockConnected = false

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = refresh()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = refresh()
    }

    private val check = object : Runnable {
        override fun run() {
            if (dockConnected) {
                val current = ForceUse.get()
                if (current != null && current != ForceUse.FORCE_ANALOG_DOCK) {
                    ForceUse.set(ForceUse.FORCE_ANALOG_DOCK, "was $current, reset by the system")
                }
                handler.postDelayed(this, CHECK_INTERVAL_MS)
            }
        }
    }

    fun start() {
        audioManager.registerAudioDeviceCallback(deviceCallback, handler)
        handler.post { refresh() }
        Log.i(TAG, "DockWatcher started")
    }

    private fun refresh() {
        val connected = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .any { it.type == AudioDeviceInfo.TYPE_DOCK || it.type == AudioDeviceInfo.TYPE_DOCK_ANALOG }
        if (connected == dockConnected) return
        dockConnected = connected
        Log.i(TAG, "Dock device ${if (connected) "connected" else "disconnected"}")
        handler.removeCallbacks(check)
        if (connected) {
            handler.post(check)
        } else {
            ForceUse.set(ForceUse.FORCE_NONE, "dock device disconnected")
        }
    }
}
