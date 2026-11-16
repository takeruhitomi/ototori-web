package jp.choiromr.mobile.omr

import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipInputStream

data class ModelSpec(val target: String, val aliases: Set<String>, val bytes: Long, val sha256: String)

/**
 * Installs a pinned, user-supplied model bundle in an app-private directory.
 * The complete directory is published only after every file has been checked.
 * Files are streamed and never loaded completely into memory.
 */
class ModelStore(private val root: File, private val version: String = "homr-0_7-396-308",
                 private val specs: List<ModelSpec> = DEFAULT_SPECS) {
    init {
        require(version.matches(Regex("[a-zA-Z0-9_-]+")))
        require(specs.isNotEmpty() && specs.map { it.target }.toSet().size == specs.size)
        require(specs.all { it.target.matches(Regex("[a-zA-Z0-9_.-]+")) && it.bytes > 0 && it.sha256.matches(Regex("[0-9a-f]{64}")) })
        val names = specs.flatMap { it.aliases + it.target }
        require(names.toSet().size == names.size) { "Duplicate model filename" }
    }

    /** Verify hashes on each open so a modified file is never used as a model. */
    fun installed(): Map<String, File>? {
        val dir = File(root, version)
        if (!File(dir, "READY").isFile) return null
        val models = specs.associate { it.target to File(dir, it.target) }
        if (specs.any { spec ->
                val file = models.getValue(spec.target)
                !file.isFile || file.length() != spec.bytes || hash(file) != spec.sha256
            }) return null
        return models
    }

    fun install(zip: InputStream, cancelled: () -> Boolean = { false }): Map<String, File> {
        installed()?.let { return it }
        check(root.exists() || root.mkdirs()) { "Cannot create model directory" }
        val finalDir = File(root, version)
        val staging = File(root, ".install-${UUID.randomUUID()}")
        check(staging.mkdir()) { "Cannot create temporary model directory" }
        var published = false
        try {
            val seen = mutableSetOf<String>()
            ZipInputStream(zip.buffered()).use { archive ->
                while (true) {
                    if (cancelled()) throw InterruptedException("Model installation cancelled")
                    val entry = archive.nextEntry ?: break
                    val name = entry.name.replace('\\', '/')
                    val components = name.split('/')
                    require(!name.startsWith('/') && components.none { it == ".." || it == "." }) { "Invalid archive path" }
                    if (entry.isDirectory) { archive.closeEntry(); continue }
                    val filename = components.last()
                    val spec = specs.singleOrNull { filename == it.target || filename in it.aliases }
                        ?: throw IllegalArgumentException("Unexpected model file: $filename")
                    require(seen.add(spec.target)) { "Duplicate model file: $filename" }
                    val digest = MessageDigest.getInstance("SHA-256")
                    val target = File(staging, spec.target)
                    var length = 0L
                    target.outputStream().buffered().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (cancelled()) throw InterruptedException("Model installation cancelled")
                            val n = archive.read(buffer)
                            if (n < 0) break
                            length += n
                            require(length <= spec.bytes) { "Model file exceeds expected size: $filename" }
                            digest.update(buffer, 0, n)
                            output.write(buffer, 0, n)
                        }
                    }
                    require(length == spec.bytes && digest.digest().hex() == spec.sha256) { "Model file failed verification: $filename" }
                    archive.closeEntry()
                }
            }
            require(seen.size == specs.size) { "The model bundle is incomplete" }
            File(staging, "READY").writeText("$version\n", Charsets.UTF_8)
            // Only replace a corrupt installation after the new bundle is
            // fully verified. A bad archive leaves the old files untouched.
            var quarantine: File? = null
            if (finalDir.exists()) {
                installed()?.let { return it }
                quarantine = File(root, ".corrupt-${UUID.randomUUID()}")
                check(finalDir.renameTo(quarantine)) { "Cannot quarantine invalid model directory" }
            }
            if (!staging.renameTo(finalDir)) {
                if (quarantine != null) check(quarantine.renameTo(finalDir)) { "Cannot restore invalid model directory" }
                error("Cannot publish model directory")
            }
            published = true
            quarantine?.deleteRecursively()
            return specs.associate { it.target to File(finalDir, it.target) }
        } finally {
            if (!published) staging.deleteRecursively()
        }
    }

    companion object {
        val DEFAULT_SPECS = listOf(
            ModelSpec("segnet.onnx", setOf("segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f.onnx"),
                57311361, "6ed36640db4ef5d223098b6d5efe4eda97c66b24a2c72faab8a018c749003a8d"),
            ModelSpec("encoder.onnx", setOf("encoder_pytorch_model_396-f6feedb42ff90087d898b0941a55d040fa6b2903.onnx"),
                52861122, "4c16df852b3789f2676b0d49f0545dab0740e4005f7b472c5252add642f5d5eb"),
            ModelSpec("decoder.onnx", setOf("decoder_pytorch_model_396-f6feedb42ff90087d898b0941a55d040fa6b2903.onnx"),
                47299551, "3e10fd5ae52d0b86792721922fcd954c283a7ed365de7446425bdabe38f3e57d"),
        )

        private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 255) }
        private fun hash(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).buffered().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
            }
            return digest.digest().hex()
        }
    }
}
