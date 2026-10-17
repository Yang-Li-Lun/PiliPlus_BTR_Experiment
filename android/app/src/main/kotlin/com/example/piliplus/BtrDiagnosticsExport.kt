package com.example.piliplus

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.system.ErrnoException
import android.system.OsConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** User-triggered SAF export only. No storage permission or persistent URI grant. */
class BtrDiagnosticsExport : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var bytes: ByteArray? = null
    private val main = Handler(Looper.getMainLooper())
    // No idle worker before export; release its stack after a short idle period.
    private val worker = ThreadPoolExecutor(0, 1, 10, TimeUnit.SECONDS, LinkedBlockingQueue())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "piliplus/btr_diagnostics_export")
        channel!!.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save") { result.notImplemented(); return }
        if (pending != null) { result.error("busy", null, null); return }
        val activity = binding?.activity
        val data = call.argument<ByteArray>("bytes")
        val name = call.argument<String>("name")
        if (activity == null || data == null || name == null ||
            !name.matches(Regex("btr-[A-Za-z0-9._-]+\\.json"))) {
            result.error("unavailable", null, null); return
        }
        pending = result
        bytes = data
        try {
            activity.startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/json"
                    putExtra(Intent.EXTRA_TITLE, name)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }, REQUEST_CODE
            )
        } catch (_: Exception) {
            finishError("picker-unavailable")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE || pending == null) return false
        if (resultCode == Activity.RESULT_CANCELED) {
            val result = pending
            clear()
            result?.success(mapOf("status" to "cancelled"))
            return true
        }
        val uri = data?.data
        val payload = bytes
        val resolver = binding?.activity?.contentResolver
        if (resultCode != Activity.RESULT_OK || uri == null || payload == null || resolver == null) {
            finishError("write-failed"); return true
        }
        val request = pending
        // Release the retained payload after the worker finishes; keep pending
        // until then to reject concurrent saves and survive configuration changes.
        worker.execute {
            try {
                val count = BtrVerifiedWrite.write(payload,
                    { resolver.openOutputStream(uri, "wt") },
                    { resolver.openInputStream(uri) })
                main.post {
                    if (pending === request) {
                        clear()
                        request?.success(mapOf("status" to "saved", "bytes" to count))
                    }
                }
            } catch (e: Exception) {
                val code = when {
                    e is BtrVerifiedWrite.VerificationFailure -> "verification-failed"
                    generateSequence<Throwable>(e) { it.cause }.take(8).any {
                        (it is ErrnoException && it.errno == OsConstants.ENOSPC) ||
                            it.message?.contains("ENOSPC", ignoreCase = true) == true ||
                            it.message?.contains("No space left on device", ignoreCase = true) == true
                    } -> "no-space"
                    else -> "write-failed"
                }
                main.post { if (pending === request) finishError(code) }
            }
        }
        return true
    }

    private fun clear() { pending = null; bytes = null }
    private fun finishError(code: String) {
        val result = pending
        clear()
        // Do not pass exception text, document URI or provider identifiers.
        result?.error(code, null, null)
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }
    private fun detach() {
        binding?.removeActivityResultListener(this)
        binding = null
    }
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        detach()
        finishError("activity-detached")
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        finishError("engine-detached")
        worker.shutdown()
    }
    private companion object { const val REQUEST_CODE = 0x4254 }
}
