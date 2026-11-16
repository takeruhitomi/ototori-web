package jp.choiromr.mobile

import java.io.*
import java.security.MessageDigest
import java.util.Properties
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProjectArchiveTest {
    @get:Rule val temp = TemporaryFolder()
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun archive(names: List<String> = listOf("project.json"),
                        declaredSize: Long = 2, hash: String = digest("{}".toByteArray()),
                        payload: ByteArray = "{}".toByteArray(), extra: String? = null,
                        namespace: String = "symbols-v1-396-308"): ByteArray {
        val manifest = Properties().apply {
            setProperty("format", "choir-omr-project"); setProperty("version", "1")
            setProperty("recognition_namespace", namespace); setProperty("count", names.size.toString())
            names.forEachIndexed { i, name ->
                setProperty("entry.$i.name", name); setProperty("entry.$i.bytes", "$declaredSize"); setProperty("entry.$i.sha256", hash)
            }
        }
        val buffer = ByteArrayOutputStream()
        ZipOutputStream(buffer).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.properties")); manifest.store(zip, null); zip.closeEntry()
            names.distinct().forEach { name -> zip.putNextEntry(ZipEntry(name)); zip.write(payload); zip.closeEntry() }
            if (extra != null) { zip.putNextEntry(ZipEntry(extra)); zip.write(payload); zip.closeEntry() }
        }
        return buffer.toByteArray()
    }
    @Test fun roundTripsScorePdfAndRawSymbolsWithoutChangingBytes() {
        val entries = linkedMapOf<String, File>()
        for ((index, name) in listOf("project.json", "source.pdf", "recognition/300/0.bin").withIndex()) {
            entries[name] = temp.newFile("source-$index").apply { writeBytes(ByteArray(140000 + index) { (it % 251).toByte() }) }
        }
        // The project size is bounded independently; these bytes are container fixtures.
        val bytes = ByteArrayOutputStream().also { ProjectArchive.write(it, entries) }.toByteArray()
        val restored = ProjectArchive.read(ByteArrayInputStream(bytes), temp.newFolder())
        assertEquals(entries.keys, restored.keys)
        entries.forEach { (name, original) -> assertArrayEquals(original.readBytes(), restored.getValue(name).readBytes()) }
    }
    @Test fun rejectsTraversalAbsolutePathsDuplicatesAndUnexpectedEntries() {
        for (name in listOf("../outside", "/absolute", "C:/outside", "recognition/300/../a.bin", "recognition/300/00.bin")) {
            assertThrows(IllegalArgumentException::class.java) {
                ProjectArchive.read(ByteArrayInputStream(archive(names = listOf("project.json", name))), temp.newFolder())
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProjectArchive.read(ByteArrayInputStream(archive(names = listOf("project.json", "project.json"))), temp.newFolder())
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProjectArchive.read(ByteArrayInputStream(archive(extra = "source.pdf")), temp.newFolder())
        }
    }
    @Test fun rejectsCorruptMissingAndOversizedPayloadsBeforeTheyCanBeRestored() {
        for (bytes in listOf(archive(hash = "0".repeat(64)), archive(declaredSize = 1),
            archive(declaredSize = 10_000_001), archive(names = listOf("source.pdf")))) {
            assertThrows(IllegalArgumentException::class.java) {
                ProjectArchive.read(ByteArrayInputStream(bytes), temp.newFolder())
            }
        }
        val onlyManifest = ByteArrayOutputStream().also { output ->
            ZipOutputStream(output).use { zip ->
                zip.putNextEntry(ZipEntry("manifest.properties"))
                zip.write("format=choir-omr-project\nversion=1\ncount=1\nentry.0.name=project.json\nentry.0.bytes=2\nentry.0.sha256=${digest("{}".toByteArray())}\n".toByteArray())
            }
        }.toByteArray()
        assertThrows(IllegalArgumentException::class.java) {
            ProjectArchive.read(ByteArrayInputStream(onlyManifest), temp.newFolder())
        }
    }
    @Test fun requiresAnEmptyPrivateDestinationAndMatchingRecognitionNamespace() {
        temp.newFile("occupied")
        assertThrows(IllegalArgumentException::class.java) {
            ProjectArchive.read(ByteArrayInputStream(archive()), temp.root)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProjectArchive.read(ByteArrayInputStream(archive(names = listOf("project.json", "recognition/300/0.bin"), namespace = "different-pipeline")), temp.newFolder())
        }
    }
}
