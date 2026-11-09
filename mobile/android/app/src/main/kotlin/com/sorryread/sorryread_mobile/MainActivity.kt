package com.sorryread.sorryread_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.view.WindowManager
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.RoundedCorner
import android.content.Context
import java.nio.charset.Charset
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import android.Manifest
import android.content.pm.PackageManager

class MainActivity : FlutterActivity() {
    private val bookFiles by lazy { LocalBookFiles(this) }
    private var pendingFont: MethodChannel.Result? = null
    private var pendingIndexStart: Pair<MethodChannel.Result, YesheIndexKind>? = null
    private val indexExecutor = Executors.newSingleThreadExecutor()
    private val comicPageExecutor = Executors.newFixedThreadPool(2)
    private val comicPages = YesheHttpTransport()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bookFiles.register(flutterEngine.dartExecutor.binaryMessenger)
        LocalStorageChannel(this, indexExecutor).register(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sorryread/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "version" -> {
                    @Suppress("DEPRECATION")
                    val info = packageManager.getPackageInfo(packageName, 0)
                    result.success(info.versionName)
                }
                "openUrl" -> {
                    try {
                        val uri = Uri.parse(call.arguments as String)
                        require(uri.scheme == "https" && !uri.host.isNullOrBlank())
                        startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("browser", "无法打开浏览器，请稍后重试。", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // Keep one surface geometry for shelf and reader. SafeArea still places
        // the shelf below visible system bars; only bar visibility changes.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sorryread/yeshe_index").setMethodCallHandler { call, result ->
            val kind = if (call.argument<Boolean>("comic") == true) YesheIndexKind.COMICS else YesheIndexKind.NOVELS
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED && pendingIndexStart == null) {
                        pendingIndexStart = result to kind
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 5302)
                    } else startIndex(result, kind)
                }
                "pause" -> { stopService(Intent(this, kind.service)); result.success(null) }
                "page" -> comicPageExecutor.execute {
                    try {
                        require(kind == YesheIndexKind.COMICS)
                        val category = call.argument<Int>("category") ?: 4
                        val number = call.argument<Int>("page") ?: 1
                        val page = comicPages.fetch(YesheCatalog.pageUrl(number, category), category).page
                        val value = mapOf("books" to page.books.map(YesheBook::toMap), "hasMore" to (page.next != null))
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("catalog", e.message ?: "漫画列表加载失败", null) }
                    }
                }
                "status", "search", "refresh" -> indexExecutor.execute {
                    try {
                        val store = YesheIndexStore.get(this, kind)
                        val value = when (call.method) {
                            "search" -> store.search(call.argument<String>("query") ?: "", call.argument<Int>("offset") ?: 0, call.argument<Int>("category"))
                            "refresh" -> { check(!kind.running) { "请先暂停缓存" }; store.refresh(); store.snapshot() }
                            else -> store.snapshot().toMutableMap().apply {
                                if (get("status") == "running" && !kind.running) put("status", "paused")
                                if (get("status") == "complete") store.scheduleUpdateCheck()
                            }
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("index", e.message ?: "本地书目操作失败", null) } }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sorryread/reader")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readerBottomClearance" -> {
                        var clearance = 4.0
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val insets = window.decorView.rootWindowInsets
                            val left = insets?.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_LEFT)?.radius ?: 0
                            val right = insets?.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_RIGHT)?.radius ?: 0
                            val radius = maxOf(left, right) / resources.displayMetrics.density.toDouble()
                            // Status information is now grouped centrally, at
                            // least 64 dp away from either rounded bottom corner.
                            val fromCenter = maxOf(0.0, radius - 64.0)
                            val curve = radius - kotlin.math.sqrt(radius * radius - fromCenter * fromCenter)
                            clearance = maxOf(clearance, curve + 4.0)
                        }
                        result.success(clearance)
                    }
                    "readerWindowInsets" -> {
                        val insets = window.decorView.rootWindowInsets
                        val density = resources.displayMetrics.density.toDouble()
                        val navigation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                            (insets?.getInsetsIgnoringVisibility(WindowInsets.Type.navigationBars())?.bottom ?: 0) / density
                        else @Suppress("DEPRECATION") ((insets?.stableInsetBottom ?: 0) / density)
                        val radius = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                            maxOf(insets?.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_LEFT)?.radius ?: 0,
                                insets?.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_RIGHT)?.radius ?: 0) / density
                        else 0.0
                        result.success(mapOf("navigation" to navigation, "radius" to radius))
                    }
                    "readerFullscreen" -> {
                        val enabled = call.arguments == true
                        // Flutter's legacy immersive mode is not sufficient on
                        // recent target SDKs. Control system bars natively too.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            window.insetsController?.apply {
                                if (enabled) {
                                    systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                                    hide(WindowInsets.Type.systemBars())
                                } else {
                                    show(WindowInsets.Type.systemBars())
                                }
                            }
                        }
                        result.success(null)
                    }
                    "batteryStatus" -> {
                        val battery = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val level = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                        result.success(mapOf(
                            "level" to if (level in 0..100) level else null,
                            "charging" to battery.isCharging
                        ))
                    }
                    "battery" -> {
                        val battery = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val level = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                        result.success(if (level in 0..100) level else null)
                    }
                    "brightness" -> {
                        val attributes = window.attributes
                        attributes.screenBrightness = (call.arguments as? Number)?.toFloat()?.coerceIn(0.02f, 1f)
                            ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        window.attributes = attributes
                        result.success(null)
                    }
                    "decode" -> {
                        val bytes = call.argument<ByteArray>("bytes")!!
                        val charset = call.argument<String>("charset")!!
                        Thread {
                            try {
                                val text = String(bytes, Charset.forName(charset))
                                runOnUiThread { result.success(text) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("charset", "页面编码不受支持", null) }
                            }
                        }.start()
                    }
                    "importFont" -> {
                        if (pendingFont != null) { result.error("busy", "请选择一个字体文件", null) }
                        else {
                            pendingFont = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "*/*"
                                }, 5301)
                            } catch (e: Exception) {
                                pendingFont = null
                                result.error("picker", "无法打开文件选择器", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startIndex(result: MethodChannel.Result, kind: YesheIndexKind) {
        if (kind.deleting) { result.error("busy", "正在删除本地书目，请稍候", null); return }
        try { startForegroundService(Intent(this, kind.service)); result.success(null) }
        catch (e: Exception) { result.error("index", "无法启动后台缓存，请保持应用在前台后重试", null) }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 5302) { pendingIndexStart?.let { (result, kind) -> startIndex(result, kind) }; pendingIndexStart = null }
    }

    @Deprecated("Activity result bridge for the reader font picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (bookFiles.onResult(requestCode, resultCode, data)) return
        if (requestCode != 5301) return
        val result = pendingFont ?: return
        pendingFont = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        Thread {
            try {
                val bytes = contentResolver.openInputStream(uri)!!.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (output.size() <= 32 * 1024 * 1024) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                if (bytes.size > 32 * 1024 * 1024) throw IllegalArgumentException("字体文件不能超过 32 MB")
                val magic = bytes.take(4).toByteArray()
                if (!(magic.contentEquals(byteArrayOf(0, 1, 0, 0)) || String(magic, Charsets.US_ASCII) == "OTTO")) {
                    throw IllegalArgumentException("请选择 TTF 或 OTF 字体文件")
                }
                runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
                runOnUiThread { result.error("font", e.message ?: "字体文件无法读取", null) }
            }
        }.start()
    }
}
