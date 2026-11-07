package io.github.atomicpel.jpegtopdf

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Работа с файлами через системные окна Android (Storage Access Framework), без сторонних плагинов:
 *  - pickImages      — выбрать одно или несколько изображений, копии кладутся в кэш приложения;
 *  - savePdf         — сохранить готовый PDF туда, куда укажет пользователь;
 *  - openPdf/sharePdf — открыть или отправить сохранённый PDF;
 *  - takeSharedImages — изображения, пришедшие через «Поделиться» из других приложений.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "jpegtopdf/io"
        const val REQ_PICK = 4101
        const val REQ_SAVE = 4102
    }

    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSaveSource: File? = null
    private var sharedPaths: List<String> = emptyList()
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val inputDir: File get() = File(cacheDir, "inputs").apply { mkdirs() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            inputDir.listFiles()?.forEach { it.delete() }   // старые копии от прошлых запусков
            handleShareIntent(intent)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickImages" -> {
                    if (!beginPending(result)) return@setMethodCallHandler
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "image/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                    launch(i, REQ_PICK)
                }
                "savePdf" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "scan.pdf"
                    if (path == null || !File(path).exists()) {
                        result.error("no_file", "PDF не найден", null); return@setMethodCallHandler
                    }
                    if (!beginPending(result)) return@setMethodCallHandler
                    pendingSaveSource = File(path)
                    val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/pdf"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    launch(i, REQ_SAVE)
                }
                "openPdf" -> result.success(startUri(call.argument<String>("uri"), Intent.ACTION_VIEW))
                "sharePdf" -> result.success(startUri(call.argument<String>("uri"), Intent.ACTION_SEND))
                "cacheDir" -> result.success(cacheDir.absolutePath)
                "takeSharedImages" -> {
                    result.success(sharedPaths)
                    sharedPaths = emptyList()
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    private fun beginPending(result: MethodChannel.Result): Boolean {
        if (pendingResult != null) {
            result.error("busy", "Уже открыто окно выбора файла", null)
            return false
        }
        pendingResult = result
        return true
    }

    private fun finishPending(value: Any?) {
        val r = pendingResult
        pendingResult = null
        r?.success(value)
    }

    private fun failPending(code: String, msg: String) {
        val r = pendingResult
        pendingResult = null
        r?.error(code, msg, null)
    }

    @Suppress("DEPRECATION")
    private fun launch(i: Intent, req: Int) {
        try {
            startActivityForResult(i, req)
        } catch (e: ActivityNotFoundException) {
            failPending("no_activity", "Нет системного окна выбора файлов")
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_PICK -> {
                if (resultCode != Activity.RESULT_OK || data == null) { finishPending(emptyList<String>()); return }
                val uris = mutableListOf<Uri>()
                data.clipData?.let { c -> for (k in 0 until c.itemCount) uris.add(c.getItemAt(k).uri) }
                if (uris.isEmpty()) data.data?.let { uris.add(it) }
                io.execute {
                    try {
                        val paths = copyToCache(uris)
                        main.post { finishPending(paths) }
                    } catch (e: Exception) {
                        main.post { failPending("read_failed", e.message ?: "Не удалось прочитать файлы") }
                    }
                }
            }
            REQ_SAVE -> {
                val src = pendingSaveSource
                pendingSaveSource = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null || src == null) { finishPending(null); return }
                io.execute {
                    try {
                        contentResolver.openOutputStream(uri, "wt")!!.use { out ->
                            src.inputStream().use { it.copyTo(out) }
                        }
                        main.post { finishPending(uri.toString()) }
                    } catch (e: Exception) {
                        main.post { failPending("write_failed", e.message ?: "Не удалось сохранить PDF") }
                    }
                }
            }
        }
    }

    private fun startUri(uriStr: String?, action: String): Boolean {
        if (uriStr == null) return false
        val uri = Uri.parse(uriStr)
        val i = Intent(action).apply {
            if (action == Intent.ACTION_SEND) {
                type = "application/pdf"
                putExtra(Intent.EXTRA_STREAM, uri)
            } else {
                setDataAndType(uri, "application/pdf")
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            startActivity(if (action == Intent.ACTION_SEND) Intent.createChooser(i, "Отправить PDF") else i)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> streamExtra(intent)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> streamListExtra(intent)?.let { uris.addAll(it) }
            else -> return
        }
        if (uris.isEmpty()) return
        intent.action = null   // не обрабатывать повторно при пересоздании
        io.execute {
            val paths = try { copyToCache(uris) } catch (e: Exception) { emptyList() }
            main.post {
                sharedPaths = sharedPaths + paths
                channel?.invokeMethod("sharedImagesAvailable", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(i: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else i.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamListExtra(i: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

    /** Копирует выбранные файлы в кэш; имя сохраняется, чтобы показать его в списке страниц. */
    private fun copyToCache(uris: List<Uri>): List<String> {
        val dir = inputDir
        return uris.mapIndexed { idx, uri ->
            val name = displayName(uri) ?: "image_$idx.jpg"
            val safe = name.replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
            val f = File(dir, "${System.nanoTime()}_$safe")
            contentResolver.openInputStream(uri)!!.use { inp -> f.outputStream().use { inp.copyTo(it) } }
            f.absolutePath
        }
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }
}
