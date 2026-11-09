package com.sorryread.sorryread_mobile

import org.junit.Test
import org.junit.Assert.*

class YesheCatalogTest {
    private fun page(next: String = "/arttype/5-2.html", total: Int = 60) = """<div class="listwap"><a class="info" title="山间 &amp; 来信" href="/artdetail-12.html">图片</a><a class="info" title="重复" href="/artdetail-12.html"></a><a class="info" title="外站" href="https://evil.invalid/artdetail-13.html"></a></div><div class="page_tip">共 $total 条</div><div class="mac_pages"><a href="$next">下一页</a></div>"""
    @Test fun catalogExtractsTitlesDeduplicatesAndRestrictsLinks() {
        val parsed = YesheCatalog.parse(page().toByteArray(), YesheCatalog.FIRST)
        assertEquals(1, parsed.books.size)
        assertEquals("山间 & 来信", parsed.books[0].title)
        assertEquals("https://yeshezy1.com/artdetail-12.html", parsed.books[0].url)
        assertEquals("https://yeshezy1.com/arttype/5-2.html", parsed.next)
        assertEquals(60, parsed.total)
        assertEquals("abc山间", YesheCatalog.normalize(" AbC 山间 "))
    }
    @Test fun rejectsLoopsChallengesExternalAndPrematureEnd() {
        for (bad in listOf(page("/arttype/5.html"), page("/arttype/5-9.html"), page("https://evil.invalid/arttype/5-2.html"), "<html>请稍后</html>", page().replace("下一页", "尾页"))) {
            assertThrows(IllegalArgumentException::class.java) { YesheCatalog.parse(bad.toByteArray(), YesheCatalog.FIRST) }
        }
        assertFalse(YesheCatalog.allowed("http://yeshezy1.com/arttype/5.html"))
        assertFalse(YesheCatalog.allowed("https://yeshezy1.com@evil.invalid/arttype/5.html"))
        assertFalse(YesheCatalog.allowed("https://yeshezy1.com/arttype/5.html?x=1"))
    }
    @Test fun lastPageCompletesNormally() {
        val parsed = YesheCatalog.parse(page(total=30).replace("下一页", "尾页").toByteArray(), YesheCatalog.FIRST)
        assertNull(parsed.next)
    }
    @Test fun selfLinkedNextEndsOnlyOnTheConfirmedLastPage() {
        val last=YesheCatalog.parse(page(next="/arttype/5-2.html",total=60).toByteArray(),YesheCatalog.pageUrl(2))
        assertNull(last.next)
        assertEquals(1,last.books.size)
        val first=YesheCatalog.parse(page(next="/arttype/5-1.html",total=30).toByteArray(),YesheCatalog.FIRST)
        assertNull(first.next)
        assertThrows(IllegalArgumentException::class.java) { YesheCatalog.parse(page(next="/arttype/5-1.html",total=60).toByteArray(),YesheCatalog.FIRST) }
    }
    @Test fun comicCatalogKeepsCoverCategoryAndUpdateFields() {
        val html = """
            <div class="listwap"><div class="list">
            <a href="/voddetail/12.html" class="pic"><img src="/cover.webp">
            <span class="type">韩国H漫</span><span class="time">2话</span></a>
            <a class="info" title="合成漫画" href="/voddetail/12.html">
            <div class="title">合成漫画</div><div class="time">2026-11-09</div></a>
            </div></div><div class="page_tip">共31条</div>
            <div class="mac_pages"><a href="/vodtype/19-2.html">下一页</a></div>
        """.trimIndent()
        val last = YesheCatalog.pageUrl(2, 19)
        val catalog = YesheCatalog.parse(html.toByteArray(), last, 19)
        assertNull(catalog.next)
        assertEquals(
            YesheBook("https://yeshezy1.com/voddetail/12.html", "合成漫画",
                "https://yeshezy1.com/cover.webp", 19, "2026-11-09", "2话"),
            catalog.books.single()
        )
        assertThrows(IllegalArgumentException::class.java) {
            YesheCatalog.parse(html.replace("/vodtype/19-2", "/vodtype/20-2").toByteArray(), last, 19)
        }
    }
}
