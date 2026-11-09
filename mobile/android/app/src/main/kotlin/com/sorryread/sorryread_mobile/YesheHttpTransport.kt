package com.sorryread.sorryread_mobile

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.GZIPInputStream

class YesheHttpException(val code: Int, val retryAt: Long, message: String) : IOException(message)

class YesheHttpTransport(
    private val onThrottle: (Long) -> Unit = {},
    private val connect: (String) -> HttpURLConnection = { URL(it).openConnection() as HttpURLConnection }
) {
    private val stopped = AtomicBoolean()
    private val connections = ConcurrentHashMap.newKeySet<HttpURLConnection>()
    private val gate = YesheRequestGate()
    val parallelism get() = gate.parallelism
    companion object {
        fun retryDelay(header: String?, now: Long = System.currentTimeMillis()): Long {
            if (header == null) return 2000
            header.trim().toLongOrNull()?.let { seconds ->
                return if (seconds > 86400) Long.MAX_VALUE / 4 else (seconds.coerceAtLeast(0) * 1000)
            }
            return try { (ZonedDateTime.parse(header.trim(), DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() - now).coerceAtLeast(0) }
                catch (_: Exception) { 2000 }
        }
    }
    fun resumeCooldown(delay: Long) { gate.slowDown(delay) }
    fun cancel() {
        stopped.set(true)
        gate.cancel()
        connections.forEach { it.disconnect() }
    }
    private fun checkActive() { if (stopped.get() || Thread.currentThread().isInterrupted) throw InterruptedException() }
    fun fetch(url: String, category: Int? = null): YesheDownloadedPage {
        val number = YesheCatalog.pageNumber(url, category)
        for (attempt in 0..2) {
            checkActive()
            try {
                val (body, bytes) = fetchOnce(url, number)
                checkActive()
                val page = YesheCatalog.parse(body, url, category)
                gate.success()
                return YesheDownloadedPage(number, page, bytes)
            } catch (e: YesheHttpException) {
                if (e.code !in setOf(408, 429, 500, 502, 503, 504)) throw e
                val delay = maxOf(2000L shl attempt, e.retryAt - System.currentTimeMillis())
                val until = System.currentTimeMillis() + delay
                checkActive()
                onThrottle(until)
                if (attempt == 2 || delay > 120000) throw YesheHttpException(e.code, until, "网站暂时限流或繁忙，已保存进度，请稍后继续")
                gate.slowDown(delay)
            } catch (e: IOException) {
                if (attempt == 2) throw e
                Thread.sleep(500L shl attempt)
            }
        }
        throw IOException("书目下载失败，已保存进度")
    }
    private fun fetchOnce(url: String, number: Int): Pair<ByteArray, Int> {
        gate.enter()
        var connection: HttpURLConnection? = null
        try {
            checkActive()
            val conn = connect(url)
            connection = conn
            connections.add(conn)
            checkActive()
            conn.connectTimeout = 15000
            conn.readTimeout = 20000
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/136.0 Mobile Safari/537.36")
            conn.setRequestProperty("Accept-Encoding", "gzip")
            val status = conn.responseCode
            if (status != 200) {
                val delay = if (status in setOf(408, 429, 500, 502, 503, 504)) retryDelay(conn.getHeaderField("Retry-After")) else 0
                throw YesheHttpException(status, System.currentTimeMillis() + delay, "网站返回 $status（第 $number 页），已保留下载进度")
            }
            val raw = conn.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    checkActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    require(output.size() <= 2 * 1024 * 1024) { "书目页面异常过大" }
                }
                output.toByteArray()
            }
            val body = if (conn.contentEncoding?.contains("gzip") == true) GZIPInputStream(raw.inputStream()).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    checkActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    require(output.size() <= 4 * 1024 * 1024) { "书目页面异常过大" }
                }
                output.toByteArray()
            } else raw
            return body to raw.size
        } finally {
            connection?.let { connections.remove(it); it.disconnect() }
            gate.leave()
        }
    }
}
