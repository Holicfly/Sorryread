package com.sorryread.sorryread_mobile

import org.jsoup.Jsoup
import java.net.URI
import java.io.ByteArrayInputStream
import java.util.Locale

data class YesheBook(
    val url: String,
    val title: String,
    val cover: String = "",
    val category: Int = 0,
    val updated: String = "",
    val episodes: String = ""
) {
    fun toMap() = mapOf("url" to url, "title" to title, "cover" to cover, "category" to category)
}
data class YeshePage(val books: List<YesheBook>, val next: String?, val total: Int)

object YesheCatalog {
    const val FIRST = "https://yeshezy1.com/arttype/5.html"
    val comicCategories = setOf(4, 19, 20, 21)
    private fun pathPrefix(category: Int?) = if (category == null) "/arttype/5" else "/vodtype/$category"
    private fun pagePath(category: Int?) = Regex("^${pathPrefix(category)}(?:-(\\d+))?\\.html$")
    fun pageUrl(number: Int, category: Int? = null): String {
        require(number >= 1 && (category == null || category in comicCategories))
        val suffix = if (number == 1) "" else "-$number"
        return "https://yeshezy1.com${pathPrefix(category)}$suffix.html"
    }
    fun pageNumber(url: String, category: Int? = null): Int {
        require(allowed(url, category = category)) { "书目分页地址无效" }
        val number = pagePath(category).matchEntire(URI(url).path)?.groupValues?.get(1)?.takeIf { it.isNotEmpty() }?.toInt() ?: 1
        require(number >= 1)
        return number
    }
    fun allowed(url: String, book: Boolean = false, category: Int? = null): Boolean = try {
        val u = URI(url)
        val path = if (!book) pagePath(category) else if (category == null) Regex("^/artdetail-\\d+\\.html$") else Regex("^/voddetail/\\d+\\.html$")
        u.scheme == "https" && u.host == "yeshezy1.com" && u.userInfo == null && (u.port == -1 || u.port == 443) && u.query == null && u.fragment == null &&
            (category == null || category in comicCategories) && path.matches(u.path)
    } catch (_: Exception) { false }
    fun normalize(text: String) = text.lowercase(Locale.ROOT).replace(Regex("\\s+"), "")
    fun parse(bytes: ByteArray, url: String, category: Int? = null): YeshePage {
        require(allowed(url, category = category)) { "书目分页地址无效" }
        val doc = Jsoup.parse(ByteArrayInputStream(bytes), null, url)
        val books = doc.select(".listwap a.info[href]").mapNotNull { a ->
            val link = a.absUrl("href")
            val title = a.attr("title").ifBlank { a.text() }.replace(Regex("\\s+"), " ").trim()
            if (!allowed(link, true, category) || title.isEmpty()) return@mapNotNull null
            if (category == null) return@mapNotNull YesheBook(link, title)
            val cover = a.closest(".list")?.selectFirst("a.pic")
            val kind = when (cover?.selectFirst(".type")?.text()) {
                "韩国H漫" -> 19
                "日本H漫" -> 20
                "3D漫画" -> 21
                else -> category
            }
            YesheBook(link, title, cover?.selectFirst("img[src]")?.absUrl("src").orEmpty(), kind,
                a.selectFirst(".time")?.text().orEmpty(), cover?.selectFirst(".time")?.text().orEmpty())
        }.distinctBy { it.url }
        val total = Regex("共\\s*(\\d+)\\s*条").find(doc.select(".page_tip").text())?.groupValues?.get(1)?.toIntOrNull()
            ?: throw IllegalArgumentException("未识别到书目总数，网站结构可能变化")
        require(total >= 0 && (books.isNotEmpty() || total == 0)) {
            if (category == null) "未识别到小说列表，已保留下载进度" else "未识别到漫画列表，已保留下载进度"
        }
        val nextNode = doc.select(".mac_pages a[href]").firstOrNull { it.text().trim().contains("下一页") }
        val page = pageNumber(url, category)
        val candidate = nextNode?.absUrl("href")
        // MacCMS keeps a self-linked "next" button on its final page.
        // Only a confirmed terminal page may interpret that link as finished.
        val next = if (candidate != null && allowed(candidate, category = category) && pageNumber(candidate, category) == page && page >= (total + 29) / 30) null else candidate
        require(next == null || (allowed(next, category = category) && next != url)) { "书目分页异常，已停止" }
        require(next != null || page >= (total + 29) / 30) { "目录尚未结束，但网站没有返回下一页" }
        if (next != null) {
            val n = pageNumber(next, category)
            require(n == page + 1) { "书目分页不连续，已停止" }
        }
        return YeshePage(books, next, total)
    }
}
