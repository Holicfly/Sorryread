package com.sorryread.sorryread_mobile

import org.junit.Test
import org.junit.Assert.*
import java.time.Instant
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class YesheRequestGateTest {
    @Test fun throttlingFallsBackToOneAndRecoversGradually() {
        val gate=YesheRequestGate()
        gate.slowDown(0); assertEquals(1,gate.parallelism)
        repeat(7) {gate.success()}; assertEquals(1,gate.parallelism)
        gate.success(); assertEquals(2,gate.parallelism)
        repeat(8) {gate.success()}; assertEquals(4,gate.parallelism)
        gate.slowDown(0); assertEquals(1,gate.parallelism)
    }
    @Test fun globalPacingAndCapacityApplyAcrossWorkers() {
        val gate=YesheRequestGate(15,2); val active=AtomicInteger(); val peak=AtomicInteger()
        val times=Collections.synchronizedList(mutableListOf<Long>())
        val pool=Executors.newFixedThreadPool(4)
        try {
            val jobs=(1..8).map {pool.submit {
                gate.enter()
                try {
                    times.add(System.nanoTime()/1_000_000)
                    val count=active.incrementAndGet(); peak.updateAndGet {maxOf(it,count)}
                    Thread.sleep(30); active.decrementAndGet()
                } finally {gate.leave()}
            }}
            jobs.forEach {it.get(2,TimeUnit.SECONDS)}
            assertTrue(peak.get()<=2)
            assertTrue(times.sorted().zipWithNext().all {(a,b)->b-a>=14})
        } finally {gate.cancel();pool.shutdownNow()}
    }
    @Test fun cancelWakesWaitingRequests() {
        val gate=YesheRequestGate(0,1); gate.enter()
        val stopped=CountDownLatch(1)
        val thread=Thread {try {gate.enter()} catch(_:InterruptedException) {stopped.countDown()} }
        thread.start(); gate.cancel(); assertTrue(stopped.await(1,TimeUnit.SECONDS)); gate.leave(); thread.join(1000)
    }
    @Test fun retryAfterAcceptsSecondsAndHttpDate() {
        assertEquals(6000L,YesheHttpTransport.retryDelay("6"))
        val now=Instant.parse("2015-10-21T07:28:00Z").toEpochMilli()
        assertEquals(6000L,YesheHttpTransport.retryDelay("Wed, 21 Oct 2015 07:28:06 GMT",now))
        assertEquals(0L,YesheHttpTransport.retryDelay("Wed, 21 Oct 2015 07:27:06 GMT",now))
        assertEquals(2000L,YesheHttpTransport.retryDelay("invalid"))
    }
}
