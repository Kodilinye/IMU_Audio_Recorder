package org.toothbrush.collector.shared

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import org.toothbrush.collector.core.Phase
import org.toothbrush.collector.core.sanitizeSuffix
import java.io.File
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Native controls sized for round watches; no collection settings hidden behind gestures. */
class CollectorActivity : Activity() {
    private val rt get() = CollectorRuntime
    private val wear get() = CaptureFactory.isWear
    private val ink = Color.rgb(237, 241, 249)
    private val muted = Color.rgb(166, 179, 198)
    private val blue = Color.rgb(74, 134, 245)
    private lateinit var page: LinearLayout
    private lateinit var stateText: TextView
    private lateinit var timeText: TextView
    private lateinit var connection: TextView
    private lateinit var detail: TextView
    private lateinit var start: Button
    private lateinit var retry: Button
    private var suffix: EditText? = null
    private var filesPage = false
    private var exportFiles: List<File> = emptyList()
    private val refresh = object : Runnable {
        override fun run() { if (!filesPage) renderStatus(); rt.main.postDelayed(this, 200) }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(11, 18, 30); window.navigationBarColor = Color.rgb(11, 18, 30)
        exportFiles = savedInstanceState?.getStringArrayList("export_files")?.map { File(it) }
            ?.filter { it.canonicalPath.startsWith(rt.root.canonicalPath + File.separator) && it.isFile }.orEmpty()
        showRecord()
    }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putStringArrayList("export_files", ArrayList(exportFiles.map { it.absolutePath }))
        super.onSaveInstanceState(outState)
    }
    override fun onResume() { super.onResume(); rt.visible = true; rt.main.post(refresh); Link.refresh(); Link.scanPending(); if (wear) Link.queueFiles() }
    override fun onPause() { rt.visible = false; rt.main.removeCallbacks(refresh); super.onPause() }
    override fun onDestroy() { CaptureFactory.detachPreview(); super.onDestroy() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun buildPage() {
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.rgb(11, 18, 30)); isFillViewport = true }
        page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(if (wear) 26 else 22), dp(if (wear) 18 else 18), dp(if (wear) 26 else 22), dp(30)) }
        scroll.addView(page)
        scroll.setOnApplyWindowInsetsListener { view, insets ->
            val bars = if (Build.VERSION.SDK_INT >= 30) insets.getInsets(android.view.WindowInsets.Type.systemBars()) else null
            view.setPadding(bars?.left ?: 0, bars?.top ?: insets.systemWindowInsetTop, bars?.right ?: 0, bars?.bottom ?: insets.systemWindowInsetBottom)
            insets
        }
        setContentView(scroll)
    }
    private fun label(text: String, size: Float, color: Int = ink, bold: Boolean = false): TextView = TextView(this).apply {
        this.text = text; textSize = size; setTextColor(color); gravity = Gravity.CENTER
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(4), 0, dp(4)); page.addView(this, LinearLayout.LayoutParams(-1, -2))
    }
    private fun button(text: String, color: Int = blue, click: () -> Unit): Button = Button(this).apply {
        this.text = text; isAllCaps = false; textSize = if (wear) 16f else 17f; setTextColor(Color.WHITE)
        background = GradientDrawable().apply { setColor(color); cornerRadius = dp(28).toFloat() }
        setOnClickListener { click() }
        page.addView(this, LinearLayout.LayoutParams(-1, dp(if (wear) 48 else 56)).apply { topMargin = dp(10) })
    }
    private fun showRecord() {
        filesPage = false; buildPage()
        label(if (wear) "COLLECTOR" else "Toothbrush Collector", if (wear) 11f else 25f, if (wear) muted else ink, true)
        if (!wear) label("Watch motion + audio · phone video", 14f, muted)
        stateText = label("Ready", if (wear) 14f else 20f, ink, true)
        if (wear) {
            start = button("Start recording") { control() }
            timeText = label("00:00.0", 26f, ink, true).apply { typeface = Typeface.MONOSPACE }
        } else {
            timeText = label("00:00.0", 40f, ink, true).apply { typeface = Typeface.MONOSPACE }
            start = button("Start recording") { control() }
        }
        connection = label("Checking companion…", if (wear) 12f else 15f, muted)
        detail = label("", if (wear) 12f else 14f, muted)
        if (!wear) {
            suffix = EditText(this).apply {
                hint = "Optional filename suffix"; setTextColor(ink); setHintTextColor(muted); isSingleLine = true
                setText(rt.prefs.getString("suffix", "")); setSelectAllOnFocus(true)
                contentDescription = "Optional filename suffix"
                filters = arrayOf(android.text.InputFilter.LengthFilter(64))
                addTextChangedListener(object : android.text.TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                        val cleaned = sanitizeSuffix(s?.toString().orEmpty())
                        rt.prefs.edit().putString("suffix", cleaned).apply(); Link.suffix(cleaned)
                    }
                    override fun afterTextChanged(s: android.text.Editable?) = Unit
                })
                page.addView(this, LinearLayout.LayoutParams(-1, dp(56)))
                setOnFocusChangeListener { _, focus -> if (!focus) saveSuffix() }
            }
            label("Front-camera preview appears when recording", 12f, muted)
            CaptureFactory.attachPreview(this, page)
        } else label("Suffix: ${rt.prefs.getString("suffix", "").orEmpty().ifEmpty { "none" }}", 11f, muted)
        retry = button(if (wear) "Send data to phone" else "Retry watch transfer", Color.rgb(38, 54, 76)) { Link.retry(); rt.transferStatus = "Transfer requested" }
        button("Saved recordings", Color.rgb(38, 54, 76)) { showFiles() }
        button("Device status", Color.rgb(38, 54, 76)) { showDeviceStatus() }
        if (!wear) label("Open both apps for a paired start. Watch-only recording works offline. A shared countdown does not guarantee precise synchronization.", 12f, muted)
        renderStatus()
    }
    private fun saveSuffix(): String {
        val clean = sanitizeSuffix(suffix?.text?.toString() ?: rt.prefs.getString("suffix", "").orEmpty())
        rt.prefs.edit().putString("suffix", clean).apply(); if (!wear) Link.suffix(clean)
        return clean
    }
    private fun control() {
        if (rt.state.active) { rt.stop(); return }
        val required = if (wear) Manifest.permission.RECORD_AUDIO else Manifest.permission.CAMERA
        if (checkSelfPermission(required) != PackageManager.PERMISSION_GRANTED && rt.prefs.getBoolean("asked_required", false) && !shouldShowRequestPermissionRationale(required)) {
            android.app.AlertDialog.Builder(this).setTitle(if (wear) "Microphone permission needed" else "Camera permission needed")
                .setMessage("Enable the required permission in app settings, then return and tap Start.")
                .setPositiveButton("Open settings") { _, _ -> startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName"))) }
                .setNegativeButton("Cancel", null).show()
            return
        }
        val needed = mutableListOf<String>()
        if (!wear && checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.CAMERA)
        if ((wear || !rt.prefs.getBoolean("asked_microphone", false)) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33 && !rt.prefs.getBoolean("asked_notifications", false)) needed.add(Manifest.permission.POST_NOTIFICATIONS)
        if (needed.isNotEmpty()) {
            rt.prefs.edit().putBoolean("asked_required", true).putBoolean("asked_microphone", true).putBoolean("asked_notifications", true).apply()
            requestPermissions(needed.toTypedArray(), 5); return
        }
        rt.startLocal(saveSuffix())
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val required = if (wear) Manifest.permission.RECORD_AUDIO else Manifest.permission.CAMERA
        rt.detail = if (checkSelfPermission(required) != PackageManager.PERMISSION_GRANTED) "${if (wear) "Microphone" else "Camera"} permission denied · recording not started"
            else if (!wear && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) "Phone microphone denied · Start will record video only"
            else "Permissions ready · tap Start when ready"
        // No delayed automatic start: cancelling a permission prompt can never leave an armed recorder.
    }
    private fun renderStatus() {
        val phase = rt.state.phase
        stateText.text = when (phase) { Phase.IDLE -> "Ready"; Phase.COUNTDOWN -> "Get ready"; Phase.STARTING -> "Opening recorder"; Phase.RECORDING -> "● Recording"; Phase.SAVING -> "Saving locally"; Phase.ERROR -> "Saved with issue" }
        stateText.setTextColor(if (phase == Phase.RECORDING) Color.rgb(255, 116, 112) else ink)
        val seconds = if (phase == Phase.COUNTDOWN) ((rt.state.deadlineElapsedMs - SystemClock.elapsedRealtime()).coerceAtLeast(0) + 999) / 1000 else
            if (phase == Phase.RECORDING && rt.startedElapsedMs > 0) (SystemClock.elapsedRealtime() - rt.startedElapsedMs) / 1000 else 0
        val tenths = if (phase == Phase.RECORDING && rt.startedElapsedMs > 0) ((SystemClock.elapsedRealtime() - rt.startedElapsedMs) / 100) % 10 else 0
        timeText.text = if (phase == Phase.COUNTDOWN) "$seconds" else String.format(Locale.US, "%02d:%02d.%d", seconds / 60, seconds % 60, tenths)
        start.text = when (phase) { Phase.COUNTDOWN, Phase.STARTING -> "Cancel"; Phase.RECORDING -> "Stop & save"; Phase.SAVING -> "Saving…"; else -> "Start recording" }
        start.isEnabled = phase != Phase.SAVING
        start.background = GradientDrawable().apply { setColor(if (rt.state.active) Color.rgb(193, 56, 62) else blue); cornerRadius = dp(28).toFloat() }
        connection.text = rt.peerSummary()
        val videoNote = if (wear && rt.state.active && !(rt.connected && rt.peerStatusFresh && rt.peerSession == rt.state.session?.id && rt.peerState == "RECORDING")) "\nPhone video not confirmed" else ""
        detail.text = rt.detail + (if (rt.state.active) " · ${rt.controlOrigin}" else "") + videoNote + "\n" + rt.transferStatus
        retry.isEnabled = !rt.state.active; suffix?.isEnabled = !rt.state.active
        if (!wear && rt.state.active) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    private fun showDeviceStatus() {
        CaptureFactory.detachPreview(); filesPage = true; buildPage()
        label("Device status", if (wear) 19f else 25f, ink, true)
        button("Back to recorder", Color.rgb(38, 54, 76)) { showRecord() }
        if (rt.state.active) button("Stop & save", Color.rgb(193, 56, 62)) { rt.stop(); showRecord() }
        label("${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE}", 14f, muted)
        label(rt.peerSummary(), 14f, muted)
        rt.prefs.getString("last_transfer_error", null)?.let { label("Last transfer issue: $it", 11f, muted) }
        label("Microphone: ${if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) "permitted" else "not permitted"}", 14f)
        if (!wear) label("Camera: ${if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) "permitted" else "not permitted"}", 14f)
        if (wear) {
            val sensors = getSystemService(android.hardware.SensorManager::class.java)
            listOf(1 to "Acceleration", 10 to "Linear acceleration", 4 to "Gyroscope", 2 to "Magnetic field", 9 to "Gravity", 11 to "Rotation vector").forEach { (type, name) ->
                label("$name: ${if (sensors.getDefaultSensor(type) != null) "available" else "absent"}", 12f, muted)
            }
            label("Motion requested at 100 Hz. Audio prefers 44.1 kHz mono PCM16. Actual rates and formats are saved in metadata.", 12f, muted)
        }
        if (!wear) {
            label("Local recordings", 16f, ink, true)
            label(rt.root.absolutePath, 11f, muted).setTextIsSelectable(true)
            button("Copy storage path", Color.rgb(38, 54, 76)) {
                (getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(android.content.ClipData.newPlainText("Recordings path", rt.root.absolutePath))
                Toast.makeText(this, "Path copied · use Export for file access", Toast.LENGTH_SHORT).show()
            }
        }
    }
    private fun showFiles() {
        CaptureFactory.detachPreview(); filesPage = true; buildPage()
        label("Saved recordings", if (wear) 19f else 25f, ink, true)
        button("Back to recorder", Color.rgb(38, 54, 76)) { showRecord() }
        val dirs = rt.root.listFiles()?.filter { it.isDirectory }?.sortedByDescending { it.lastModified() }.orEmpty()
        if (dirs.isEmpty()) label("Your saved sessions will appear here.", 14f, muted)
        dirs.forEach { dir ->
            val files = dir.listFiles()?.filter { it.isFile && !it.name.startsWith('.') }?.sortedBy { it.name }.orEmpty()
            if (files.isEmpty()) return@forEach
            val stem = files.first().name.substringAfter("metadata_", files.first().name.substringAfter("native_", files.first().name.substringAfter("audio_"))).substringBeforeLast('.')
            label(stem, if (wear) 12f else 17f, ink, true)
            val motion = files.any { it.extension == "csv" }; val audio = files.any { it.extension == "wav" }; val video = files.any { it.extension == "mp4" }
            label("${if (motion) "✓" else "—"} Motion  ${if (audio) "✓" else "—"} Audio  ${if (video) "✓" else "—"} Video", if (wear) 11f else 14f, muted)
            if (!video) label(if (wear) "Video is stored on phone when available" else "Phone video absent", 12f, Color.rgb(239, 192, 111))
            val current = rt.state.active && rt.state.session?.id == dir.name
            label(if (current) "Recording in progress" else "${files.size} files · ${files.sumOf { it.length() } / 1024} KB", 12f, muted)
            if (!wear) {
                label(files.joinToString("\n") { it.name }, 11f, muted)
                button("Export session ZIP", Color.rgb(38, 54, 76)) {
                    exportFiles = files
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/zip")
                        .putExtra(Intent.EXTRA_TITLE, "collector_${stem}_${dir.name.take(8)}.zip"), 8)
                }.isEnabled = !current
            }
        }
        if (!wear) label("File presence shows available files, not proof of complete capture. Inspect each session’s metadata for failures and actual formats. Watch originals are retained after transfer.", 12f, muted)
        button("Refresh list", Color.rgb(38, 54, 76)) { Link.scanPending(); showFiles() }
    }
    @Deprecated("Platform callback retained for simple native Activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 8 || resultCode != RESULT_OK) return
        val uri = data?.data ?: return; val snapshot = exportFiles.toList()
        if (snapshot.isEmpty()) { Toast.makeText(this, "Select the session again to export", Toast.LENGTH_LONG).show(); return }
        Link.io.execute {
            val result = runCatching {
                ZipOutputStream(contentResolver.openOutputStream(uri, "w") ?: error("Cannot open export destination")).use { zip ->
                    snapshot.forEach { file -> zip.putNextEntry(ZipEntry("${file.parentFile!!.name}/${file.name}")); file.inputStream().use { it.copyTo(zip) }; zip.closeEntry() }
                }
            }
            rt.main.post { Toast.makeText(this, result.fold({ "Export complete" }, { "Export failed: ${it.message}" }), Toast.LENGTH_LONG).show() }
        }
    }
}
