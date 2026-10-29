package com.sorryread.sorryread_mobile

/** Shared launch pacing and rate-limit cooldown across all network workers. */
class YesheRequestGate(private val spacingMs: Long = 200, private val maxParallelism: Int = 4) {
    private val lock = java.lang.Object()
    private var active = 0
    private var nextStart = 0L
    private var cooldown = 0L
    private var cancelled = false
    private var successes = 0
    @Volatile var parallelism = maxParallelism
        private set
    private fun now() = System.nanoTime() / 1_000_000
    fun enter() {
        synchronized(lock) {
            while (true) {
                if (cancelled || Thread.currentThread().isInterrupted) throw InterruptedException()
                val time = now()
                val ready = maxOf(nextStart, cooldown)
                if (active < parallelism && time >= ready) {
                    active++
                    nextStart = time + spacingMs
                    return
                }
                lock.wait((ready - time).coerceIn(10, 100))
            }
        }
    }
    fun leave() { synchronized(lock) { active--; lock.notifyAll() } }
    fun slowDown(delayMs: Long) {
        synchronized(lock) {
            parallelism = 1
            successes = 0
            cooldown = maxOf(cooldown, now() + delayMs.coerceAtLeast(0))
            lock.notifyAll()
        }
    }
    fun success() {
        synchronized(lock) {
            if (parallelism < maxParallelism && ++successes >= 8) {
                parallelism = minOf(maxParallelism, parallelism * 2)
                successes = 0
                lock.notifyAll()
            }
        }
    }
    fun cancel() { synchronized(lock) { cancelled = true; lock.notifyAll() } }
}
