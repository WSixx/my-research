package br.com.brd.mywebviewplaygorund

import android.content.Context
import android.graphics.Outline
import android.util.AttributeSet
import android.view.View
import android.view.ViewOutlineProvider
import android.webkit.WebView

class MyCustomWebView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : WebView(context, attrs, defStyleAttr) {

    private var cornerRadius: Float = 24f * context.resources.displayMetrics.density

    init {
        outlineProvider = object : ViewOutlineProvider() {
            // Shape só no TOP
            override fun getOutline(view: View, outline: Outline) {
                val extraHeight = cornerRadius.toInt()
                outline.setRoundRect(
                    0, 
                    0, 
                    view.width, 
                    view.height + extraHeight, 
                    cornerRadius
                )
            }
        }
        clipToOutline = true
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        invalidateOutline()
    }

    fun setCornerRadius(radiusPx: Float) {
        cornerRadius = radiusPx
        invalidateOutline()
    }
}