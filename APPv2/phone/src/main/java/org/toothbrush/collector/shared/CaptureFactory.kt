package org.toothbrush.collector.shared

import android.app.Activity
import android.content.Context
import android.widget.LinearLayout
import androidx.camera.view.PreviewView
import org.toothbrush.collector.phone.PhoneCapture

object CaptureFactory {
    const val isWear = false

    fun create(context: Context): Capture = PhoneCapture(context)

    fun attachPreview(activity: Activity, container: LinearLayout) {
        val preview = PreviewView(activity).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FIT_CENTER
            contentDescription = "Front camera recording preview"
        }
        container.addView(preview, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            (220 * activity.resources.displayMetrics.density).toInt()
        ))
        PhoneCapture.setPreviewSurfaceProvider(preview.surfaceProvider)
    }

    fun detachPreview() = PhoneCapture.setPreviewSurfaceProvider(null)
}
