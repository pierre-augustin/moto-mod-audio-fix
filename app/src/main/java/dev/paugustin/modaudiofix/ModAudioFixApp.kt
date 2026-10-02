package dev.paugustin.modaudiofix

import android.app.Application
import android.os.Process

private const val PER_USER_RANGE = 100000

/**
 * Persistent application (android:persistent="true", privileged system app): the
 * system starts this process at boot and keeps it alive, so the DockWatcher can
 * follow the dock device and repair force_use whatever the foreground user is.
 */
class ModAudioFixApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // force_use is global: one watcher, in the system user's process, is enough.
        if (Process.myUid() / PER_USER_RANGE == 0) {
            DockWatcher(this).start()
        }
    }
}
