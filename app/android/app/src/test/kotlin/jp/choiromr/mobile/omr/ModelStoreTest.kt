package jp.choiromr.mobile.omr

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ModelStoreTest {
    @get:Rule val temp = TemporaryFolder()
    private val first = "first model".toByteArray()
    private val second = "second model".toByteArray()

    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun store(): ModelStore = ModelStore(temp.root, "fixture", listOf(
        ModelSpec("first.onnx", setOf("original-first.onnx"), first.size.toLong(), hash(first)),
        ModelSpec("second.onnx", emptySet(), second.size.toLong(), hash(second)),
    ))

    private fun zip(vararg entries: Pair<String, ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { archive -> entries.forEach { (name, bytes) ->
            archive.putNextEntry(ZipEntry(name)); archive.write(bytes); archive.closeEntry()
        } }
        return output.toByteArray()
    }

    @Test fun defaultManifestIsValid() {
        assertNull(ModelStore(temp.root).installed())
    }

    @Test fun verifiedModelsArePublishedAndCanBeReopened() {
        val store = store()
        val installed = store.install(ByteArrayInputStream(zip("original-first.onnx" to first, "second.onnx" to second)))
        assertArrayEquals(first, installed.getValue("first.onnx").readBytes())
        assertNotNull(store.installed())
        installed.getValue("first.onnx").writeText("tampered!!")
        assertNull(store.installed())
        val repaired = store.install(ByteArrayInputStream(zip("first.onnx" to first, "second.onnx" to second)))
        assertArrayEquals(first, repaired.getValue("first.onnx").readBytes())
        assertNotNull(store.installed())
    }

    @Test fun partialAndCorruptBundlesNeverBecomeInstalled() {
        val store = store()
        assertThrows(IllegalArgumentException::class.java) {
            store.install(ByteArrayInputStream(zip("first.onnx" to first)))
        }
        assertNull(store.installed())
        assertThrows(IllegalArgumentException::class.java) {
            store.install(ByteArrayInputStream(zip("first.onnx" to first, "second.onnx" to "wrong value!".toByteArray())))
        }
        assertNull(store.installed())
        assertFalse(temp.root.listFiles()!!.any { it.name.startsWith(".install-") })
    }

    @Test fun rejectsTraversalAndCancellationWithoutPublishing() {
        val store = store()
        assertThrows(IllegalArgumentException::class.java) {
            store.install(ByteArrayInputStream(zip("../first.onnx" to first, "second.onnx" to second)))
        }
        assertThrows(InterruptedException::class.java) {
            store.install(ByteArrayInputStream(zip("first.onnx" to first, "second.onnx" to second))) { true }
        }
        assertNull(store.installed())
        assertFalse(temp.root.listFiles()!!.any { it.name.startsWith(".install-") })
    }
}
