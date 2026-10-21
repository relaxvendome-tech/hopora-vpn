package PACKAGE_NAME

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Mode discret (active par defaut) : appli masquee dans les applis
        // recentes et captures d'ecran bloquees.
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val disguised = prefs.getBoolean("flutter.disguise", false)
        if (prefs.getBoolean("flutter.discreet", true) || disguised) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        if (disguised) setTaskLabel(getString(R.string.calc_name))
    }

    @Suppress("DEPRECATION")
    private fun setTaskLabel(label: String) {
        try {
            setTaskDescription(ActivityManager.TaskDescription(label))
        } catch (_: Exception) {
        }
    }

    /** Bascule l'icone de lancement : Hopora <-> Calculatrice. */
    private fun setDisguise(on: Boolean) {
        val pm = packageManager
        val calc = ComponentName(this, "$packageName.LauncherCalc")
        val normal = ComponentName(this, "$packageName.LauncherDefault")
        val en = PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        val dis = PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        pm.setComponentEnabledSetting(if (on) calc else normal, en, PackageManager.DONT_KILL_APP)
        pm.setComponentEnabledSetting(if (on) normal else calc, dis, PackageManager.DONT_KILL_APP)
        setTaskLabel(if (on) getString(R.string.calc_name) else "Hopora")
    }

    /** Efface les traces locales : caches, fichiers, donnees Tor, autres preferences. */
    private fun wipeLocal() {
        fun clear(dir: File?) {
            dir?.listFiles()?.forEach { it.deleteRecursively() }
        }
        clear(cacheDir)
        clear(filesDir)
        clear(noBackupFilesDir)
        clear(getDir("TorService", MODE_PRIVATE))
        externalCacheDir?.let { clear(it) }
        File(applicationInfo.dataDir, "shared_prefs").listFiles()?.forEach {
            if (it.name != "FlutterSharedPreferences.xml") it.delete()
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
                } else if (call.method == "disguise") {
                    try {
                        setDisguise(call.arguments == true)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                } else if (call.method == "wipe") {
                    Thread {
                        try {
                            wipeLocal()
                        } catch (_: Exception) {
                        }
                        runOnUiThread { result.success(null) }
                    }.start()
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

        // ----- Mode Tor -----
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hopora/tor")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        pendingTransport = call.argument<String>("transport") ?: "direct"
                        pendingNotif = call.argument<String>("notif") ?: "Tor"
                        pendingBridges = call.argument<String>("bridges") ?: ""
                        val prep = VpnService.prepare(this)
                        if (prep != null) {
                            TorVpnService.state = "permission"
                            @Suppress("DEPRECATION")
                            startActivityForResult(prep, TOR_REQUEST)
                        } else {
                            startTor()
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        torIntent(TorVpnService.ACTION_STOP)?.let { startService(it) }
                        result.success(null)
                    }
                    "transport" -> {
                        torIntent(TorVpnService.ACTION_TRANSPORT)
                            ?.putExtra(TorVpnService.EXTRA_TRANSPORT, call.argument<String>("transport"))
                            ?.putExtra(TorVpnService.EXTRA_BRIDGES, call.argument<String>("bridges") ?: "")
                            ?.let { startService(it) }
                        result.success(null)
                    }
                    "newnym" -> {
                        torIntent(TorVpnService.ACTION_NEWNYM)?.let { startService(it) }
                        result.success(null)
                    }
                    "status" -> result.success(TorVpnService.status())
                    "fetch" -> {
                        // Requete HTTPS envoyee A TRAVERS Tor (resolution DNS par Tor).
                        val url = call.argument<String>("url") ?: ""
                        Thread {
                            val body = try {
                                val port = TorVpnService.socksPort
                                if (port <= 0) throw Exception("no-socks")
                                val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", port))
                                val c = URL(url).openConnection(proxy) as HttpURLConnection
                                c.connectTimeout = 25000
                                c.readTimeout = 25000
                                c.setRequestProperty("User-Agent", "Mozilla/5.0")
                                c.inputStream.bufferedReader().use { it.readText() }
                            } catch (e: Exception) {
                                null
                            }
                            runOnUiThread { result.success(body) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private var pendingTransport = "direct"
    private var pendingNotif = "Tor"
    private var pendingBridges = ""

    private fun torIntent(action: String): Intent? =
        if (TorVpnService.state == "off" && action != TorVpnService.ACTION_START) null
        else Intent(this, TorVpnService::class.java).setAction(action)

    private fun startTor() {
        val i = Intent(this, TorVpnService::class.java)
            .setAction(TorVpnService.ACTION_START)
            .putExtra(TorVpnService.EXTRA_TRANSPORT, pendingTransport)
            .putExtra(TorVpnService.EXTRA_NOTIF, pendingNotif)
            .putExtra(TorVpnService.EXTRA_BRIDGES, pendingBridges)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
    }

    // Reprend la connexion VPN une fois l'autorisation Android accordee.
    @Deprecated("Requis par le moteur OpenVPN")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == TOR_REQUEST) {
            if (resultCode == RESULT_OK) startTor() else TorVpnService.state = "denied"
        } else {
            OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK)
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        private const val TOR_REQUEST = 25
    }
}
