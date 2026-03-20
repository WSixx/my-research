package br.com.brd.mywebviewplaygorund

import android.graphics.Bitmap
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.fragment.app.setFragmentResult
import br.com.brd.mywebviewplaygorund.databinding.FragmentWebviewBinding

class WebviewFragment : Fragment() {

    private var _binding: FragmentWebviewBinding? = null
    private val binding get() = _binding!!

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentWebviewBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        
        binding.webview.apply {
            webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                    super.onPageStarted(view, url, favicon)
                    Log.d("WebviewFragment", "Iniciando carregamento: $url")
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    super.onPageFinished(view, url)
                    Log.d("WebviewFragment", "Carregamento finalizado: $url")
                    
                    setFragmentResult("webview_loaded", bundleOf("url" to url))
                    
                    Toast.makeText(context, "Página carregada!", Toast.LENGTH_SHORT).show()
                }
            }
            
            settings.javaScriptEnabled = true
            loadUrl("https://www.bing.com")
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}