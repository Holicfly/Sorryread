package com.sorryread.sorryread_mobile

import android.app.Service
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicLong

class YesheIndexService : Service() {
    companion object {
        @Volatile var running = false
        private val generation = AtomicLong()
        const val PAUSE = "yeshe.pause"
        const val CHANNEL = "yeshe_catalog"
        const val NOTIFICATION = 5302
    }
    @Volatile private var stopped = false
    @Volatile private var transport: YesheHttpTransport? = null
    @Volatile private var queue: YesheDownloadQueue? = null
    private var worker: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL, "夜社书目缓存", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE) { pause(); return START_NOT_STICKY }
        if (running) return START_NOT_STICKY
        stopped = false
        running = true
        val token = generation.incrementAndGet()
        try {
            val notice = notification("正在准备本地书目…", 0, 0)
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION, notice)
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:yeshe-catalog").also { it.acquire(2 * 60 * 60 * 1000L) }
        } catch (e: Exception) {
            running = false
            YesheIndexStore.get(this).set("status" to "paused", "error" to "后台缓存无法启动，请返回页面重试：${e.javaClass.simpleName}")
            stopSelf()
            return START_NOT_STICKY
        }
        worker = Thread({ download(token) }, "yeshe-catalog").also { it.start() }
        // Do not restart a foreground service from an unattended background launch.
        // The committed next-page checkpoint is resumed explicitly from the app.
        return START_NOT_STICKY
    }
    private fun notification(text: String, page: Int, total: Int): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val pause = PendingIntent.getService(this, 1, Intent(this, YesheIndexService::class.java).setAction(PAUSE), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("正在缓存夜社书目").setContentText(text).setContentIntent(open)
            .setOnlyAlertOnce(true).setOngoing(true).setProgress(total, page, total == 0)
            .addAction(Notification.Action.Builder(null, "暂停", pause).build()).build()
    }
    private fun pause() { stopped = true; transport?.cancel(); queue?.cancel(); worker?.interrupt(); if (worker == null) stopSelf() }
    override fun onTimeout(startId: Int, fgsType: Int) { pause(); stopSelf() }
    override fun onDestroy() {
        pause()
        releaseWakeLock()
        super.onDestroy()
    }
    @Synchronized private fun releaseWakeLock() { if (wakeLock?.isHeld == true) wakeLock?.release() }
    private fun download(token: Long) {
        val store = YesheIndexStore.get(this)
        val http = YesheHttpTransport(onThrottle = { until -> if (!stopped && token == generation.get()) store.recordThrottle(until) })
        transport = http
        try {
            if (store.state("status") == "complete") return
            val cooldown = store.state("cooldownUntil", "0").toLong() - System.currentTimeMillis()
            if (cooldown > 120000) throw YesheHttpException(429, System.currentTimeMillis()+cooldown, "网站要求暂缓请求，请稍后继续缓存")
            if (cooldown > 0) http.resumeCooldown(cooldown)
            store.set("status" to "running", "error" to "", "sessionPages" to "0", "sessionElapsed" to "0", "parallelism" to http.parallelism.toString())
            val sessionStart = SystemClock.elapsedRealtime()
            var lastCommit = sessionStart
            var sessionPages = 0
            var lastNotification = 0L
            val jobs = YesheDownloadQueue(fetch = http::fetch, stopped = { stopped || token != generation.get() }, commit = { result ->
                if (stopped || token != generation.get()) throw InterruptedException()
                val now = SystemClock.elapsedRealtime()
                store.commit(result.page, now-lastCommit, result.bytes, result.number, ++sessionPages, now-sessionStart, http.parallelism)
                lastCommit = now
                if (now-lastNotification >= 1000 || result.page.next == null) {
                    val state = store.snapshot()
                    val pages = (state["pages"] as Number).toInt()
                    val total = ((state["total"] as Number).toInt()+29)/30
                    getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification("已处理 $pages/$total 页 · 已缓存 ${state["count"]} 本", pages, total))
                    lastNotification = now
                }
            })
            queue = jobs
            jobs.run(store.state("next", YesheCatalog.FIRST).ifBlank { YesheCatalog.FIRST })
        } catch (e: Exception) {
            if (!stopped && token == generation.get()) {
                if (e is YesheHttpException && e.retryAt > System.currentTimeMillis()) store.recordThrottle(e.retryAt)
                store.set("status" to "paused", "error" to (e.message ?: "缓存中断，已保留进度，点击继续"))
            }
        } finally {
            queue?.cancel()
            http.cancel()
            if (token == generation.get()) {
                try { if (store.state("status") == "running") store.set("status" to "paused") }
                finally {
                    running = false
                    releaseWakeLock()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }
}
