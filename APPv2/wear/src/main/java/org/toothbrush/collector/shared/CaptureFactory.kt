package org.toothbrush.collector.shared

import android.app.Activity
import android.content.Context
import android.widget.LinearLayout
import org.toothbrush.collector.wear.WearCapture

object CaptureFactory {
    const val isWear = true
    fun create(context: Context): Capture = WearCapture(context)
    fun attachPreview(activity: Activity, container: LinearLayout) = Unit
    fun detachPreview() = Unit
}
