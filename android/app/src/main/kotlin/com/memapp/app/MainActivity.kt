package com.memapp.app

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Android's Storage Access Framework to Dart for JSON import/export.
 *
 * This is deliberately hand-rolled rather than using file_picker: that package
 * is pinned to win32 ^5 and cannot resolve alongside the rest of this app's
 * dependencies. ACTION_OPEN_DOCUMENT / ACTION_CREATE_DOCUMENT need no runtime
 * storage permission on any supported Android version.
 *
 * FlutterActivity extends plain Activity, not ComponentActivity, so this uses
 * startActivityForResult rather than the ActivityResult APIs.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.memapp.app/files"
        const val REQ_OPEN = 4011
        const val REQ_CREATE = 4012
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickJson" -> {
                if (!claim(result)) return
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    // Some file managers hide .json behind application/json, so
                    // cast a wide net and validate the contents in Dart.
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf("application/json", "text/plain", "text/json")
                    )
                }
                runCatching { startActivityForResult(intent, REQ_OPEN) }
                    .onFailure { fail("no_picker", it.message) }
            }

            "saveJson" -> {
                if (!claim(result)) return
                pendingContent = call.argument<String>("content").orEmpty()
                val name = call.argument<String>("fileName") ?: "memapp-export.json"
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/json"
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                runCatching { startActivityForResult(intent, REQ_CREATE) }
                    .onFailure { fail("no_picker", it.message) }
            }

            else -> result.notImplemented()
        }
    }

    /** Guards against a second dialog while one is already open. */
    private fun claim(result: MethodChannel.Result): Boolean {
        if (pendingResult != null) {
            result.error("busy", "A file dialog is already open", null)
            return false
        }
        pendingResult = result
        return true
    }

    private fun finish(value: Any?) {
        pendingResult?.success(value)
        pendingResult = null
        pendingContent = null
    }

    private fun fail(code: String, message: String?) {
        pendingResult?.error(code, message, null)
        pendingResult = null
        pendingContent = null
    }

    @Deprecated("startActivityForResult is the only option on FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_OPEN && requestCode != REQ_CREATE) return

        // User backed out: null, not an error — the Dart side treats it as a no-op.
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            finish(null)
            return
        }
        val uri = data.data!!

        when (requestCode) {
            REQ_OPEN -> runCatching {
                contentResolver.openInputStream(uri)!!.use { it.readBytes().toString(Charsets.UTF_8) }
            }.onSuccess { finish(it) }
                .onFailure { fail("read_failed", it.message) }

            REQ_CREATE -> {
                val body = pendingContent.orEmpty()
                runCatching {
                    contentResolver.openOutputStream(uri, "wt")!!.use {
                        it.write(body.toByteArray(Charsets.UTF_8))
                    }
                }.onSuccess { finish(uri.toString()) }
                    .onFailure { fail("write_failed", it.message) }
            }
        }
    }
}
