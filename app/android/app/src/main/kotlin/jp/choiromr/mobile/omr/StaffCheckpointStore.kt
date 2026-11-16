package jp.choiromr.mobile.omr

import java.io.*
import java.security.MessageDigest
import java.util.UUID

/** Immutable, checksum-verified results addressed by exact prepared pixels and pipeline. */
class StaffCheckpointStore(private val root: File, private val scope: String = "", private val pipeline: String =
    "staff-v2-attention-x-max608-normalize7931-1738:" + SymbolVocabulary.HASH + ":" +
        ModelStore.DEFAULT_SPECS.joinToString(":") { it.sha256 }) {
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
    private fun key(pixels: ByteArray): String {
        require(pixels.size == 1280 * 256)
        val sha = MessageDigest.getInstance("SHA-256")
        sha.update(pipeline.toByteArray(Charsets.UTF_8)); sha.update(0.toByte())
        sha.update(scope.toByteArray(Charsets.UTF_8)); sha.update(0.toByte()); sha.update(pixels)
        return sha.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    private fun file(key: String) = File(root, "$key.bin")
    private fun validate(t: StaffToken) {
        require(t.rhythm in 0 until 259 && t.pitch in 0 until 72 && t.lift in 0 until 7 &&
            t.position in 0 until 3 && t.articulation in 0 until 54 && t.slur in 0 until 5)
    }
    fun read(pixels: ByteArray): DecodeResult? {
        val key = key(pixels)
        val target = file(key)
        if (!target.isFile) return null
        return try {
            require(target.length() in 100..20000)
            val bytes = target.readBytes()
            val payload = bytes.copyOfRange(0, bytes.size - 32)
            require(MessageDigest.isEqual(digest(payload), bytes.copyOfRange(payload.size, bytes.size)))
            DataInputStream(ByteArrayInputStream(payload)).use { input ->
                require(input.readInt() == 0x53544632 && input.readUTF() == key)
                val eos = input.readBoolean()
                val count = input.readInt()
                require(count in 0..608 && input.available() == count * 28)
                val tokens = List(count) { StaffToken(input.readInt(), input.readInt(), input.readInt(),
                    input.readInt(), input.readInt(), input.readInt(), input.readFloat()).also(::validate) }
                DecodeResult(tokens, eos, 0, 0)
            }
        } catch (_: Exception) {
            // A partial, stale or corrupt entry is recomputed, never used as symbols.
            target.delete()
            null
        }
    }
    fun write(pixels: ByteArray, result: DecodeResult) {
        require(result.tokens.size <= 608)
        result.tokens.forEach(::validate)
        val key = key(pixels)
        if (read(pixels) != null) return
        check(root.isDirectory || root.mkdirs()) { "Cannot create staff checkpoint directory" }
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).use { output ->
            output.writeInt(0x53544632); output.writeUTF(key)
            output.writeBoolean(result.reachedEos); output.writeInt(result.tokens.size)
            result.tokens.forEach {
                output.writeInt(it.rhythm); output.writeInt(it.pitch); output.writeInt(it.lift)
                output.writeInt(it.position); output.writeInt(it.articulation); output.writeInt(it.slur)
                output.writeFloat(it.x)
            }
        }
        val payload = buffer.toByteArray()
        val staging = File(root, ".pending-${UUID.randomUUID()}")
        try {
            FileOutputStream(staging).use { output ->
                output.write(payload); output.write(digest(payload)); output.fd.sync()
            }
            // Only a complete synced file becomes visible. Recognition has one owner.
            check(staging.renameTo(file(key))) { "Cannot publish staff checkpoint" }
        } finally { staging.delete() }
    }
}
