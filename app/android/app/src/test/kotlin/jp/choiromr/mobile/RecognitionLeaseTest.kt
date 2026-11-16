package jp.choiromr.mobile

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class RecognitionLeaseTest {
    @Test fun onlyOneConcurrentRecognitionMayLoadModels() {
        val pool = Executors.newFixedThreadPool(8)
        val ready = CountDownLatch(8)
        val start = CountDownLatch(1)
        val owners = (0 until 8).map { "job-$it" }
        try {
            val results = owners.map { id -> pool.submit<Boolean> {
                ready.countDown()
                check(start.await(5, TimeUnit.SECONDS))
                RecognitionLease.acquire(id)
            } }
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            start.countDown()
            val acquired = results.map { it.get(5, TimeUnit.SECONDS) }
            assertEquals(1, acquired.count { it })
            val winner = owners[acquired.indexOf(true)]
            RecognitionLease.release("not-the-owner")
            assertTrue(RecognitionLease.busy())
            assertFalse(RecognitionLease.acquire("another-job"))
            RecognitionLease.release(winner)
            assertFalse(RecognitionLease.busy())
            assertTrue(RecognitionLease.acquire("next-job"))
            RecognitionLease.release("next-job")
        } finally {
            start.countDown()
            pool.shutdownNow()
            owners.forEach { RecognitionLease.release(it) }
            RecognitionLease.release("next-job")
        }
    }
}
