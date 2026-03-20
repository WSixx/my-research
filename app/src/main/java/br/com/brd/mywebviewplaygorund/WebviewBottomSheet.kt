package br.com.brd.mywebviewplaygorund

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import br.com.brd.mywebviewplaygorund.databinding.LayoutWebviewBottomSheetBinding

class WebviewBottomSheet : BottomSheetDialogFragment() {

    private var _binding: LayoutWebviewBottomSheetBinding? = null
    private val binding get() = _binding!!

    override fun getTheme(): Int = R.style.Theme_App_WebviewBottomSheetM3

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = LayoutWebviewBottomSheetBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        
        binding.webviewContainer.visibility = View.INVISIBLE
        
        val webviewFragment = WebviewFragment()
        
        childFragmentManager.beginTransaction()
            .replace(R.id.webview_container, webviewFragment)
            .commit()

        childFragmentManager.setFragmentResultListener("webview_loaded", viewLifecycleOwner) { _, _ ->
            binding.webviewContainer.visibility = View.VISIBLE
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }

    companion object {
        const val TAG = "WebviewBottomSheet"
        fun newInstance() = WebviewBottomSheet()
    }
}