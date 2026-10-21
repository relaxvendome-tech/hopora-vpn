package PACKAGE_NAME

// Mode Tor de Hopora : tout le trafic du telephone passe par le reseau Tor
// (3 relais chiffres), avec des ponts anti-censure (Snowflake, obfs4, meek).
//
//  appli -> interface VPN -> hev-socks5-tunnel -> SOCKS de Tor -> reseau Tor
//
// Les requetes DNS sont interceptees localement (mapdns) puis resolues par
// le relais de sortie Tor : aucune requete DNS ne sort en clair.

import IPtProxy.Controller
import IPtProxy.OnTransportEvents
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import org.torproject.jni.TorService
import java.io.File
import java.util.concurrent.Executors

object TProxyService {
    @JvmStatic external fun TProxyStartService(configPath: String, fd: Int): Boolean
    @JvmStatic external fun TProxyStopService(): Boolean
    @JvmStatic external fun TProxyIsRunning(): Boolean
    @JvmStatic external fun TProxyGetStats(): LongArray?

    init {
        System.loadLibrary("hev-socks5-tunnel")
    }
}

/** Ponts publics integres (les memes que Tor Browser et Orbot). */
object TorBridges {
    val obfs4 = listOf(
        "obfs4 212.83.43.74:443 39562501228A4D5E27FCA4C0C81A01EE23AE3EE4 cert=PBwr+S8JTVZo6MPdHnkTwXJPILWADLqfMGoVvhZClMq/Urndyd42BwX9YFJHZnBB3H0XCw iat-mode=1",
        "obfs4 146.57.248.225:22 10A6CD36A537FCE513A322361547444B393989F0 cert=K1gDtDAIcUfeLqbstggjIw2rtgIKqdIhUlHp82XRqNSq/mtAjp1BIC9vHKJ2FAEpGssTPw iat-mode=0",
        "obfs4 212.83.43.95:443 BFE712113A72899AD685764B211FACD30FF52C31 cert=ayq0XzCwhpdysn5o0EyDUbmSOx3X/oTEbzDMvczHOdBJKlvIdHHLJGkZARtT4dcBFArPPg iat-mode=1",
        "obfs4 51.222.13.177:80 5EDAC3B810E12B01F6FD8050D2FD3E277B289A08 cert=2uplIpLQ0q9+0qMFrK5pkaYRDOe460LL9WHBvatgkuRr/SL31wBOEupaMMJ6koRE6Ld0ew iat-mode=0",
        "obfs4 45.145.95.6:27015 C5B7CD6946FF10C5B3E89691A7D3F2C122D2117C cert=TD7PbUO0/0k6xYHMPW3vJxICfkMZNdkRrb63Zhl5j9dW3iRGiCx0A7mPhe5T2EDzQ35+Zw iat-mode=0",
        "obfs4 37.218.245.14:38224 D9A82D2F9C2F65A18407B1D2B764F130847F8B5D cert=bjRaMrr1BRiAW8IE9U5z27fQaYgOhX1UCmOpg2pFpoMvo6ZgQMzLsaTzzQNTlm7hNcb+Sg iat-mode=0",
        "obfs4 209.148.46.65:443 74FAD13168806246602538555B5521A0383A1875 cert=ssH+9rP8dG2NLDN2XuFw63hIO/9MNNinLmxQDpVa+7kTOa9/m+tGWT1SmSYpQ9uTBGa6Hw iat-mode=0",
    )
    const val SF_URL = "https://1098762253.rsc.cdn77.org/"
    const val SF_FRONTS = "app.datapacket.com,www.datapacket.com"
    const val SF_ICE = "stun:stun.epygi.com:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.mixvoip.com:3478,stun:stun.telnyx.com:3478,stun:stun.hot-chilli.net:3478,stun:stun.fitauto.ru:3478,stun:stun.m-online.net:3478"
    val snowflake = listOf(
        "snowflake 192.0.2.4:80 8838024498816A039FCBBAB14E6F40A0843051FA fingerprint=8838024498816A039FCBBAB14E6F40A0843051FA url=$SF_URL fronts=$SF_FRONTS ice=$SF_ICE utls-imitate=hellorandomizedalpn",
        "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=$SF_URL fronts=$SF_FRONTS ice=$SF_ICE utls-imitate=hellorandomizedalpn",
    )
    val meek = listOf(
        "meek_lite 192.0.2.20:80 url=https://1603026938.rsc.cdn77.org front=www.phpmyadmin.net utls=HelloRandomizedALPN",
    )

    fun ptName(t: String): String? = when (t) {
        "obfs4" -> "obfs4"
        "snowflake" -> "snowflake"
        "meek" -> "meek_lite"
        else -> null
    }

    fun lines(t: String): List<String> = when (t) {
        "obfs4" -> obfs4
        "snowflake" -> snowflake
        "meek" -> meek
        else -> emptyList()
    }
}

/** Transports enfichables (Go, via IPtProxy). Une seule instance par processus. */
object Pt {
    var dir = ""
    val controller: Controller by lazy {
        Controller(dir, false, false, "ERROR", object : OnTransportEvents {
            override fun connected(name: String?) {}
            override fun error(name: String?, error: Exception?) {}
            override fun stopped(name: String?, error: Exception?) {}
        })
    }
}

class TorVpnService : VpnService() {
    companion object {
        const val ACTION_START = "hopora.tor.START"
        const val ACTION_STOP = "hopora.tor.STOP"
        const val ACTION_TRANSPORT = "hopora.tor.TRANSPORT"
        const val ACTION_NEWNYM = "hopora.tor.NEWNYM"
        const val EXTRA_TRANSPORT = "transport"
        const val EXTRA_NOTIF = "notif"
        private const val CHANNEL = "hopora_tor"
        private const val NOTIF_ID = 4242

        @Volatile var state = "off"          // off | starting | on | stopping | error | denied
        @Volatile var progress = 0
        @Volatile var summary = ""
        @Volatile var transport = "direct"
        @Volatile var socksPort = 0
        @Volatile var error = ""
        @Volatile var since = 0L
        @Volatile var phaseStartedAt = 0L

        fun status(): Map<String, Any> = mapOf(
            "state" to state,
            "progress" to progress,
            "summary" to summary,
            "transport" to transport,
            "socks" to socksPort,
            "error" to error,
            "since" to since,
            "phaseStartedAt" to phaseStartedAt,
        )
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var tun: ParcelFileDescriptor? = null
    @Volatile private var tor: TorService? = null
    private var bound = false
    @Volatile private var hevRunning = false
    private var activePt: String? = null
    private var notifText = "Tor"

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            tor = (binder as? TorService.LocalBinder)?.service
            Thread { monitor() }.start()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            tor = null
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopAll()
                return START_NOT_STICKY
            }
            ACTION_TRANSPORT -> {
                val t = intent.getStringExtra(EXTRA_TRANSPORT) ?: "direct"
                worker.execute { switchTransport(t) }
            }
            ACTION_NEWNYM -> worker.execute {
                try {
                    tor?.torControlConnection?.signal("NEWNYM")
                } catch (_: Exception) {
                }
            }
            else -> {
                notifText = intent?.getStringExtra(EXTRA_NOTIF) ?: notifText
                goForeground()
                if (state != "starting" && state != "on") {
                    start(intent?.getStringExtra(EXTRA_TRANSPORT) ?: "direct")
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        val b = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Hopora", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            b.setContentIntent(
                PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE)
            )
        }
        return b.setSmallIcon(applicationInfo.icon)
            .setContentTitle("Hopora")
            .setContentText(notifText)
            .setOngoing(true)
            .build()
    }

    private fun start(t: String) {
        state = "starting"
        progress = 0
        summary = ""
        error = ""
        transport = t
        since = 0L
        socksPort = 0
        phaseStartedAt = System.currentTimeMillis()
        try {
            // L'interface est etablie AVANT Tor : pendant le demarrage, rien ne
            // peut sortir en dehors du tunnel (pas de fuite).
            tun = establishTun()
            if (tun == null) {
                fail("vpn")
                return
            }
        } catch (e: Exception) {
            fail(e.message ?: "vpn")
            return
        }
        worker.execute {
            try {
                Pt.dir = File(cacheDir, "pt").absolutePath
                val port = startPt(t)
                writeTorrc(torLines(t, port))
                main.post {
                    bound = bindService(Intent(this, TorService::class.java), conn, BIND_AUTO_CREATE)
                    if (!bound) fail("tor")
                }
            } catch (e: Exception) {
                fail(e.message ?: "pt")
            }
        }
    }

    private fun establishTun(): ParcelFileDescriptor? {
        val b = Builder()
            .setSession("Hopora")
            .setMtu(8500)
            .addAddress("198.18.0.1", 32)
            .addAddress("fc00::1", 128)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer("198.18.0.2")
        // Tor lui-meme tourne dans cette appli : elle doit sortir directement.
        b.addDisallowedApplication(packageName)
        if (Build.VERSION.SDK_INT >= 29) b.setMetered(false)
        return b.establish()
    }

    private fun startPt(t: String): Long {
        val name = TorBridges.ptName(t) ?: return 0L
        val c = Pt.controller
        if (t == "snowflake") {
            c.snowflakeIceServers = TorBridges.SF_ICE
            c.snowflakeBrokerUrl = TorBridges.SF_URL
            c.snowflakeFrontDomains = TorBridges.SF_FRONTS
            c.snowflakeAmpCacheUrl = ""
            c.snowflakeSqsUrl = ""
            c.snowflakeSqsCreds = ""
        }
        c.start(name, null)
        activePt = name
        return c.port(name)
    }

    private fun stopPt() {
        val name = activePt ?: return
        try {
            Pt.controller.stop(name)
        } catch (_: Exception) {
        }
        activePt = null
    }

    private fun torLines(t: String, port: Long): List<String> {
        val name = TorBridges.ptName(t)
        if (name == null || port !in 1L..65535L) return listOf("UseBridges 0")
        return listOf("UseBridges 1", "ClientTransportPlugin $name socks5 127.0.0.1:$port") +
            TorBridges.lines(t).map { "Bridge $it" }
    }

    private fun writeTorrc(transportLines: List<String>) {
        val base = listOf(
            "AvoidDiskWrites 1",
            "SafeSocks 0",
            "TestSocks 0",
            "ClientOnly 1",
            "DormantCanceledByStartup 1",
        )
        TorService.getTorrc(this).writeText((base + transportLines).joinToString("\n") + "\n")
    }

    private fun switchTransport(t: String) {
        val c = tor?.torControlConnection ?: return
        try {
            stopPt()
            val port = startPt(t)
            val lines = torLines(t, port)
            transport = t
            progress = 0
            summary = ""
            state = "starting"
            since = 0L
            phaseStartedAt = System.currentTimeMillis()
            c.resetConf(listOf("UseBridges", "ClientTransportPlugin", "Bridge"))
            c.setConf(lines)
            c.setConf("DisableNetwork", "1")
            c.setConf("DisableNetwork", "0")
            writeTorrc(lines)
        } catch (e: Exception) {
            error = e.message ?: "switch"
        }
    }

    private val progressRe = Regex("PROGRESS=(\\d+)")
    private val summaryRe = Regex("SUMMARY=\"([^\"]*)\"")

    private fun monitor() {
        while (state == "starting" || state == "on") {
            val t = tor ?: break
            try {
                if (!hevRunning) {
                    val p = t.socksPort
                    if (p > 0) {
                        socksPort = p
                        startHev(p)
                    }
                }
                val phase = t.getInfo("status/bootstrap-phase")
                if (phase != null) {
                    progressRe.find(phase)?.let { progress = it.groupValues[1].toInt() }
                    summaryRe.find(phase)?.let { summary = it.groupValues[1] }
                    if (progress >= 100 && hevRunning && state == "starting") {
                        state = "on"
                        since = System.currentTimeMillis()
                    }
                }
            } catch (_: Exception) {
            }
            try {
                Thread.sleep(700)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    private fun startHev(port: Int) {
        val fd = tun?.fd ?: return
        val conf = File(cacheDir, "hev.yml")
        conf.writeText(
            """
            misc:
              log-level: warn
              task-stack-size: 81920
            tunnel:
              mtu: 8500
              ipv4: 198.18.0.1
              ipv6: 'fc00::1'
            socks5:
              port: $port
              address: 127.0.0.1
              udp: 'udp'
            mapdns:
              address: 198.18.0.2
              port: 53
              network: 240.0.0.0
              netmask: 240.0.0.0
              cache-size: 10000
            """.trimIndent() + "\n"
        )
        hevRunning = TProxyService.TProxyStartService(conf.absolutePath, fd)
    }

    private fun fail(msg: String) {
        error = msg
        cleanup()
        state = "error"
        main.post {
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun cleanup() {
        try {
            if (hevRunning) TProxyService.TProxyStopService()
        } catch (_: Throwable) {
        }
        hevRunning = false
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        if (bound) {
            try {
                unbindService(conn)
            } catch (_: Exception) {
            }
            bound = false
        }
        tor = null
        stopPt()
        socksPort = 0
        progress = 0
        since = 0L
    }

    private fun stopAll() {
        state = "stopping"
        cleanup()
        state = "off"
        stopForegroundCompat()
        stopSelf()
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
    }

    override fun onRevoke() {
        stopAll()
        super.onRevoke()
    }

    override fun onDestroy() {
        if (state == "starting" || state == "on") {
            cleanup()
            state = "off"
        }
        worker.shutdown()
        super.onDestroy()
    }
}
