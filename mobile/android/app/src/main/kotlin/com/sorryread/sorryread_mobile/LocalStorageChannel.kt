package com.sorryread.sorryread_mobile

import android.app.Activity
import android.content.Intent
import android.os.StatFs
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor

class LocalStorageChannel(private val activity: Activity, private val executor: Executor) {
    private val novels = YesheIndexKind.NOVELS
    private val cacheRoots get() = listOf(activity.cacheDir) + activity.externalCacheDirs.filterNotNull()
    private val policy get() = StorageFiles(File(activity.filesDir, "reading"), cacheRoots)

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "sorryread/local_storage").setMethodCallHandler { call, result ->
            if (call.method !in listOf("snapshot", "clearCache", "deleteYesheIndex")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val deleting = call.method == "deleteYesheIndex"
            if (deleting) {
                if (novels.deleting) {
                    result.error("busy", "正在删除书目，请稍候", null)
                    return@setMethodCallHandler
                }
                // Gate new starts before stopping the worker. Never unlink a live SQLite DB.
                novels.deleting = true
                activity.stopService(Intent(activity, YesheIndexService::class.java))
            }
            executor.execute {
                try {
                    var failures = 0
                    when (call.method) {
                        "clearCache" -> failures = policy.clear()
                        "deleteYesheIndex" -> {
                            val deadline = SystemClock.elapsedRealtime() + 10000
                            while (novels.running && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50)
                            check(!novels.running) { "后台书目任务尚未停止，请稍后重试" }
                            YesheIndexStore.get(activity).deleteIndex()
                        }
                    }
                    val value = snapshot().toMutableMap().apply { put("failedFiles", failures) }
                    activity.runOnUiThread { result.success(value) }
                } catch (e: Exception) {
                    activity.runOnUiThread { result.error("storage", e.message ?: "存储操作失败，请重试", null) }
                } finally {
                    if (deleting) novels.deleting = false
                }
            }
        }
    }

    private fun snapshot(): Map<String, Any> {
        val index = YesheIndexStore.get(activity).snapshot()
        val app = activity.applicationInfo
        val roots = listOf(File(app.dataDir)) + activity.getExternalFilesDirs(null).filterNotNull() + cacheRoots
        val files = policy.files(roots)
        val cache = files.filter(policy::isCache).sumOf { it.length() }
        val downloads = (index["size"] as Number).toLong()
        // Installed APKs are part of necessary occupancy; no system-wide usage permission needed.
        val packageBytes = (listOf(app.sourceDir) + (app.splitSourceDirs?.toList() ?: emptyList()))
            .distinct().sumOf { File(it).length() }
        val total = files.sumOf { it.length() } + packageBytes
        val disk = StatFs(app.dataDir)
        return mapOf(
            "necessary" to (total - cache - downloads).coerceAtLeast(0),
            "downloads" to downloads, "cache" to cache,
            "deviceTotal" to disk.totalBytes, "deviceFree" to disk.availableBytes,
            "indexCount" to index.getValue("count"), "indexUpdated" to (index["updated"] ?: 0L),
            "indexRunning" to novels.running
        )
        // Future explicit book/media downloads belong to a separate managed directory.
        // Add their summary and deletion policy here when implemented; never treat them as cache.
    }
}
