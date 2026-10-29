package com.sorryread.sorryread_mobile

import org.jsoup.Jsoup
import java.net.URI
import java.io.ByteArrayInputStream
import java.util.Locale

data class YesheBook(val url: String, val title: String)
data class YeshePage(val books: List<YesheBook>, val next: String?, val total: Int)

object YesheCatalog {
    const val FIRST = "https://yeshezy1.com/arttype/5.html"
    fun pageUrl(number: Int): String { require(number >= 1); return if (number == 1) FIRST else "https://yeshezy1.com/arttype/5-$number.html" }
    fun pageNumber(url: String): Int {
        require(allowed(url)) { "书目分页地址无效" }
        val number = Regex("5-(\\d+)\\.html").find(URI(url).path)?.groupValues?.get(1)?.toInt() ?: 1
        require(number >= 1)
        return number
    }
    fun allowed(url: String, book: Boolean = false): Boolean = try {
        val u = URI(url)
        u.scheme == "https" && u.host == "yeshezy1.com" && u.userInfo == null && (u.port == -1 || u.port == 443) && u.query == null && u.fragment == null &&
            (if (book) Regex("^/artdetail-\\d+\\.html$") else Regex("^/arttype/5(?:-\\d+)?\\.html$")).matches(u.path)
    } catch (_: Exception) { false }
    fun normalize(text: String) = text.lowercase(Locale.ROOT).replace(Regex("\\s+"), "")
    fun parse(bytes: ByteArray, url: String): YeshePage {
        require(allowed(url)) { "书目分页地址无效" }
        val doc = Jsoup.parse(ByteArrayInputStream(bytes), null, url)
        val books = doc.select(".listwap a.info[href]").mapNotNull { a ->
            val link = a.absUrl("href")
            val title = a.attr("title").ifBlank { a.text() }.replace(Regex("\\s+"), " ").trim()
            if (!allowed(link, true) || title.isEmpty()) null else YesheBook(link, title)
        }.distinctBy { it.url }
        val total = Regex("共\\s*(\\d+)\\s*条").find(doc.select(".page_tip").text())?.groupValues?.get(1)?.toIntOrNull()
            ?: throw IllegalArgumentException("未识别到书目总数，网站结构可能变化")
        require(total >= 0 && (books.isNotEmpty() || total == 0)) { "未识别到小说列表，已保留下载进度" }
        val nextNode = doc.select(".mac_pages a[href]").firstOrNull { it.text().trim().contains("下一页") }
        val page = pageNumber(url)
        val candidate = nextNode?.absUrl("href")
        // MacCMS keeps a self-linked "next" button on its final page.
        // Only a confirmed terminal page may interpret that link as finished.
        val next = if (candidate != null && allowed(candidate) && pageNumber(candidate) == page && page >= (total + 29) / 30) null else candidate
        require(next == null || (allowed(next) && next != url)) { "书目分页异常，已停止" }
        require(next != null || page >= (total + 29) / 30) { "目录尚未结束，但网站没有返回下一页" }
        if (next != null) {
            val n = Regex("5-(\\d+)\\.html").find(URI(next).path)?.groupValues?.get(1)?.toIntOrNull()
            require(n == page + 1) { "书目分页不连续，已停止" }
        }
        return YeshePage(books, next, total)
    }
}
