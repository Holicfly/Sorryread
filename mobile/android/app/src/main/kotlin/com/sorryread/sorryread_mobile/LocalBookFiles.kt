package com.sorryread.sorryread_mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.Locale
import java.util.UUID

internal class LocalBookFiles(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private val root get() = File(activity.cacheDir, "book-picker")
    private val limit = 200L * 1024 * 1024

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "sorryread/local_books").setMethodCallHandler { call, result ->
            when (call.method) {
                "choose" -> {
                    if (pending != null) { result.error("busy", "正在选择图书", null); return@setMethodCallHandler }
                    pending = result
                    try {
                        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "application/epub+zip",
                                "application/x-mobipocket-ebook", "application/octet-stream"))
                        }, 5303)
                    } catch (error: Exception) {
                        pending = null
                        result.error("picker", "无法打开文件选择器", null)
                    }
                }
                "decodeGb18030" -> Thread {
                    try {
                        val bytes = call.arguments as ByteArray
                        require(bytes.size <= limit)
                        val decoder = Charset.forName("GB18030").newDecoder()
                            .onMalformedInput(CodingErrorAction.REPORT)
                            .onUnmappableCharacter(CodingErrorAction.REPORT)
                        val text = decoder.decode(ByteBuffer.wrap(bytes)).toString()
                        activity.runOnUiThread { result.success(text) }
                    } catch (error: Exception) {
                        activity.runOnUiThread { result.error("encoding", "无法识别 TXT 编码", null) }
                    }
                }.start()
                else -> result.notImplemented()
            }
        }
    }

    fun onResult(request: Int, code: Int, intent: Intent?): Boolean {
        if (request != 5303) return false
        val result = pending ?: return true
        pending = null
        if (code != Activity.RESULT_OK || intent == null) { result.success(emptyList<Any>()); return true }
        val uris = linkedSetOf<Uri>()
        intent.data?.let { uris.add(it) }
        intent.clipData?.let { clips -> for (i in 0 until clips.itemCount) uris.add(clips.getItemAt(i).uri) }
        Thread {
            root.mkdirs()
            root.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000 }?.forEach { it.delete() }
            val files = uris.map { uri ->
                var name = "图书"
                var output: File? = null
                try {
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                        ?.use { if (it.moveToFirst()) name = it.getString(0) ?: name }
                    val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                    require(ext in setOf("txt", "epub", "mobi")) { "仅支持 TXT、EPUB、MOBI" }
                    val file = File(root, "${UUID.randomUUID()}.$ext")
                    output = file
                    activity.contentResolver.openInputStream(uri)!!.use { input ->
                        file.outputStream().use { target ->
                            val buffer = ByteArray(64 * 1024)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= limit) { "文件超过 200 MiB" }
                                target.write(buffer, 0, count)
                            }
                            require(total > 0) { "文件为空" }
                        }
                    }
                    mapOf("name" to name, "path" to file.path)
                } catch (error: Exception) {
                    output?.delete()
                    mapOf("name" to name, "error" to (error.message ?: "文件无法读取"))
                }
            }
            activity.runOnUiThread { result.success(files) }
        }.start()
        return true
    }
}
