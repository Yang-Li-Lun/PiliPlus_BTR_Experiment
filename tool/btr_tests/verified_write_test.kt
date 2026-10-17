package com.example.piliplus

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path

/** JVM test of the exact production I/O verifier, not an Android SAF acceptance. */
fun main(args: Array<String>) {
    val directory = Path.of(args.single())
    Files.createDirectories(directory)
    val path = Files.createTempFile(directory, "btr-verified-", ".json")
    val payload = ("{\"diagnostic\":\"" + "診斷🎬".repeat(12000) + "\"}").toByteArray(Charsets.UTF_8)
    var cases = 0
    fun mustFail(label: String, block: () -> Unit) {
        try { block(); error("Expected failure: $label") }
        catch (_: IOException) { cases++; println("PASS $label") }
    }
    try {
        check(BtrVerifiedWrite.write(payload, { Files.newOutputStream(path) }, { Files.newInputStream(path) }) == payload.size)
        check(Files.readAllBytes(path).contentEquals(payload))
        cases++; println("PASS real UTF-8 file read-back ${payload.size} bytes")
        mustFail("null output provider") { BtrVerifiedWrite.write(payload, { null }, { ByteArrayInputStream(payload) }) }
        mustFail("write failure / storage full") { BtrVerifiedWrite.write(payload,
            { object : OutputStream() { override fun write(b: Int) { throw IOException("ENOSPC") } } },
            { ByteArrayInputStream(payload) }) }
        mustFail("flush failure") { BtrVerifiedWrite.write(payload,
            { object : ByteArrayOutputStream() { override fun flush() { throw IOException() } } },
            { ByteArrayInputStream(payload) }) }
        mustFail("close failure") { BtrVerifiedWrite.write(payload,
            { object : ByteArrayOutputStream() { override fun close() { throw IOException() } } },
            { ByteArrayInputStream(payload) }) }
        mustFail("null input provider") { BtrVerifiedWrite.write(payload, { ByteArrayOutputStream() }, { null }) }
        mustFail("truncated read-back") { BtrVerifiedWrite.write(payload, { ByteArrayOutputStream() }, { ByteArrayInputStream(payload.copyOf(20000)) }) }
        mustFail("same length corrupted read-back") { BtrVerifiedWrite.write(payload, { ByteArrayOutputStream() },
            { ByteArrayInputStream(payload.clone().also { it[20] = 0 }) }) }
        mustFail("extra trailing bytes") { BtrVerifiedWrite.write(payload, { ByteArrayOutputStream() }, { ByteArrayInputStream(payload + byteArrayOf(0)) }) }
        println("$cases/$cases PASS; Android picker/cancellation/provider behavior NOT RUN")
    } finally { Files.deleteIfExists(path) }
}
