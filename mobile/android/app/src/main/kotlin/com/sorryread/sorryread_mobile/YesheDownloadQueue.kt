package com.sorryread.sorryread_mobile

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

data class YesheDownloadedPage(val number: Int, val page: YeshePage, val bytes: Int)

/** Bounded look-ahead. Only the coordinator commits, always without page gaps. */
class YesheDownloadQueue(
    private val fetch: (String) -> YesheDownloadedPage,
    private val commit: (YesheDownloadedPage) -> Unit,
    private val parallelism: Int = 4,
    private val stopped: () -> Boolean = { false }
) {
    init { require(parallelism in 1..4) }
    private val cancelled = AtomicBoolean()
    private val started = AtomicBoolean()
    private val pending = ConcurrentHashMap<Int, Future<YesheDownloadedPage>>()
    private val pool = Executors.newFixedThreadPool(parallelism) { task ->
        Thread(task, "yeshe-page").apply { isDaemon = true }
    }
    fun cancel() {
        cancelled.set(true)
        pending.values.forEach { it.cancel(true) }
        pool.shutdownNow()
    }
    private fun checkActive() {
        if (cancelled.get() || stopped() || Thread.currentThread().isInterrupted) throw InterruptedException()
    }
    fun run(startUrl: String) {
        check(!started.getAndSet(true))
        var expected = YesheCatalog.pageNumber(startUrl)
        var scheduled = expected
        try {
            pending[expected] = pool.submit<YesheDownloadedPage> { checkActive(); fetch(startUrl) }
            while (true) {
                checkActive()
                val result = try { pending.getValue(expected).get() }
                    catch (e: ExecutionException) { throw (e.cause as? Exception ?: e) }
                checkActive()
                require(result.number == expected) { "书目页序异常，未写入不连续数据" }
                val next = result.page.next
                require(next == null || YesheCatalog.pageNumber(next) == expected + 1) { "书目分页不连续" }
                commit(result)
                pending.remove(expected)
                if (next == null) break
                val last = maxOf(expected + 1, (result.page.total + 29) / 30)
                expected++
                while (pending.size < parallelism && scheduled < last) {
                    checkActive()
                    val number = ++scheduled
                    pending[number] = pool.submit<YesheDownloadedPage> { checkActive(); fetch(YesheCatalog.pageUrl(number)) }
                }
            }
        } finally { cancel(); pending.clear() }
    }
}
