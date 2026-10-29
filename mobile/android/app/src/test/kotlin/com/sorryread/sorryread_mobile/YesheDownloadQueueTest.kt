package com.sorryread.sorryread_mobile

import org.junit.Test
import org.junit.Assert.*
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class YesheDownloadQueueTest {
    private fun result(number: Int, pages: Int = 6) = YesheDownloadedPage(number, YeshePage(
        listOf(YesheBook("https://yeshezy1.com/artdetail-$number.html", "书名 $number")),
        if (number == pages) null else YesheCatalog.pageUrl(number+1), pages*30), 200)
    @Test fun concurrentResponsesCommitInOrderAndBoundTheWindow() {
        val active = AtomicInteger(); val peak = AtomicInteger()
        val secondStarted = CountDownLatch(1); val thirdFinished = CountDownLatch(1)
        val finished = Collections.synchronizedList(mutableListOf<Int>())
        val commits = mutableListOf<Int>()
        YesheDownloadQueue(fetch = { url ->
            val n = YesheCatalog.pageNumber(url)
            val count = active.incrementAndGet(); peak.updateAndGet { maxOf(it,count) }
            try {
                if (n == 2) { secondStarted.countDown(); check(thirdFinished.await(2,TimeUnit.SECONDS)) }
                if (n == 3) { check(secondStarted.await(2,TimeUnit.SECONDS)); finished.add(3); thirdFinished.countDown() }
                else finished.add(n)
                result(n)
            } finally { active.decrementAndGet() }
        }, commit = { commits.add(it.number) }).run(YesheCatalog.FIRST)
        assertEquals((1..6).toList(), commits)
        assertTrue(finished.indexOf(3)<finished.indexOf(2))
        assertTrue(peak.get() in 2..4)
        assertEquals(0,active.get())
    }
    @Test fun failureAtGapNeverCommitsLaterPages() {
        val commits = mutableListOf<Int>()
        val queue = YesheDownloadQueue(fetch = { url ->
            val n = YesheCatalog.pageNumber(url)
            if (n == 3) throw IOException("synthetic page failure")
            result(n)
        }, commit = { commits.add(it.number) })
        assertThrows(IOException::class.java) { queue.run(YesheCatalog.FIRST) }
        assertEquals(listOf(1,2), commits)
    }
    @Test fun cancellationCannotCommitLateResponsesAndResumeStartsAtCheckpoint() {
        val started = CountDownLatch(1)
        val commits = Collections.synchronizedList(mutableListOf<Int>())
        val failure = AtomicReference<Throwable>()
        val queue = YesheDownloadQueue(fetch = { url ->
            val n=YesheCatalog.pageNumber(url)
            if(n==2) { started.countDown(); Thread.sleep(5000) }
            result(n)
        }, commit={commits.add(it.number)})
        val thread=Thread { try { queue.run(YesheCatalog.FIRST) } catch(e:Throwable) { failure.set(e) } }
        thread.start(); assertTrue(started.await(2,TimeUnit.SECONDS)); queue.cancel(); thread.join(2000)
        assertFalse(thread.isAlive); assertNotNull(failure.get()); assertEquals(listOf(1),commits)
        YesheDownloadQueue(fetch={result(YesheCatalog.pageNumber(it))},commit={commits.add(it.number)}).run(YesheCatalog.pageUrl(2))
        assertEquals((1..6).toList(),commits)
    }
    @Test fun lastPageResumeDoesNotFetchOutsideCatalog() {
        val requested=mutableListOf<Int>(); val commits=mutableListOf<Int>()
        YesheDownloadQueue(fetch={val n=YesheCatalog.pageNumber(it); requested.add(n); result(n)},commit={commits.add(it.number)}).run(YesheCatalog.pageUrl(6))
        assertEquals(listOf(6),requested); assertEquals(listOf(6),commits)
    }
    @Test fun wrongPageResponseIsRejectedBeforeCommit() {
        val commits=mutableListOf<Int>()
        val queue=YesheDownloadQueue(fetch={result(3)},commit={commits.add(it.number)})
        assertThrows(IllegalArgumentException::class.java) { queue.run(YesheCatalog.FIRST) }
        assertTrue(commits.isEmpty())
    }
}
