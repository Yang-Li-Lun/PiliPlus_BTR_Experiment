package com.example.piliplus

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/** Stream close/flush errors and read-back mismatches must never become success. */
internal object BtrVerifiedWrite {
    class VerificationFailure : IOException()

    fun write(bytes: ByteArray, output: () -> OutputStream?, input: () -> InputStream?): Int {
        (output() ?: throw IOException()).use {
            it.write(bytes)
            it.flush()
        }
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        (input() ?: throw VerificationFailure()).use {
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = it.read(buffer)
                if (read < 0) break
                if (read == 0) throw VerificationFailure()
                count += read
                if (count > bytes.size) throw VerificationFailure()
                digest.update(buffer, 0, read)
            }
        }
        val expected = MessageDigest.getInstance("SHA-256").digest(bytes)
        if (count != bytes.size.toLong() || !MessageDigest.isEqual(expected, digest.digest())) {
            throw VerificationFailure()
        }
        return bytes.size
    }
}
