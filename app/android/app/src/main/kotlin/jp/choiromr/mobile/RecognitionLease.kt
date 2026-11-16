package jp.choiromr.mobile

import java.util.concurrent.atomic.AtomicReference

/** Avoid loading a second set of OMR models into a low-memory device. */
object RecognitionLease {
    private val owner = AtomicReference<String?>(null)
    fun acquire(id: String): Boolean = owner.compareAndSet(null, id)
    fun release(id: String) { owner.compareAndSet(id, null) }
    fun busy(): Boolean = owner.get() != null
}
