package PACKAGE_NAME

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Mode discret (active par defaut) : appli masquee dans les applis
        // recentes et captures d'ecran bloquees.
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        if (prefs.getBoolean("flutter.discreet", true)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hopora/secure")
            .setMethodCallHandler { call, result ->
                if (call.method == "set") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else if (call.method == "vpnSettings") {
                    // Reglage Android « VPN permanent » + « Bloquer sans VPN » (kill switch)
                    try {
                        startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                    } catch (e: Exception) {
                        startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    // Reprend la connexion VPN une fois l'autorisation Android accordee.
    @Deprecated("Requis par le moteur OpenVPN")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK)
        super.onActivityResult(requestCode, resultCode, data)
    }
}
