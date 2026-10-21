import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:http/http.dart' as http;
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n.dart';

const privacyUrl =
    'https://docs.google.com/document/d/1tQjFS1UTiuDBasafS3ISdxoqun_xpiiz7NTTHG_L2Dc/view';

/// Duree maximale d'une session VPN gratuite (4 h).
const maxSessionSeconds = 4 * 3600;

late SharedPreferences prefs;
const _secureChannel = MethodChannel('hopora/secure');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  L.init(WidgetsBinding.instance.platformDispatcher.locale);
  runApp(const HoporaApp());
  AdsManager.init();
}

// ---------------------------------------------------------------------------
// Publicite : consentement RGPD + interstitiel avant chaque connexion
// ---------------------------------------------------------------------------

class AdsManager {
  // Remplace automatiquement par votre vrai identifiant via les secrets GitHub
  // (ADMOB_INTERSTITIAL_ID). Par defaut : identifiant de TEST de Google.
  static const interstitialId = String.fromEnvironment(
    'ADMOB_INTERSTITIAL_ID',
    defaultValue: 'ca-app-pub-3940256099942544/1033173712',
  );

  static InterstitialAd? _ad;
  static bool _ready = false;

  static void init() {
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () {
        ConsentForm.loadAndShowConsentFormIfRequired((FormError? _) {
          _start();
        });
      },
      (FormError _) => _start(),
    );
  }

  static Future<void> _start() async {
    if (_ready) return;
    try {
      if (!await ConsentInformation.instance.canRequestAds()) return;
      _ready = true;
      await MobileAds.instance.initialize();
      _load();
    } catch (_) {}
  }

  static void _load() {
    InterstitialAd.load(
      adUnitId: interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _ad = ad,
        onAdFailedToLoad: (_) => _ad = null,
      ),
    );
  }

  /// Affiche la pub si elle est prete, puis lance [action].
  /// Sans pub disponible, l'action part tout de suite (jamais bloquant).
  static Future<void> showThen(Future<void> Function() action) async {
    final ad = _ad;
    if (ad == null) {
      if (_ready) _load();
      await action();
      return;
    }
    _ad = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _load();
        action();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _load();
        action();
      },
    );
    await ad.show();
  }
}

class HoporaApp extends StatelessWidget {
  const HoporaApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3D5AFE);
    return MaterialApp(
      title: 'Hopora VPN',
      debugShowCheckedModeBanner: false,
      locale: Locale(L.lang),
      supportedLocales: L.supported.map((c) => Locale(c)).toList(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const ServerListPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Modele + recuperation des serveurs VPN Gate
// ---------------------------------------------------------------------------

class VpnServer {
  final String host;
  final String ip;
  final int score;
  final int ping;
  final int speed; // bits/s
  final String country;
  final String countryCode;
  final int sessions;
  final int uptimeMs;
  final String operator;
  final String configB64;

  VpnServer({
    required this.host,
    required this.ip,
    required this.score,
    required this.ping,
    required this.speed,
    required this.country,
    required this.countryCode,
    required this.sessions,
    required this.uptimeMs,
    required this.operator,
    required this.configB64,
  });

  double get speedMbps => speed / 1000000;

  String get flag => flagOf(countryCode);

  late final String rawConfig =
      utf8.decode(base64.decode(configB64), allowMalformed: true);

  /// Adresse, port et protocole du serveur OpenVPN (ligne "remote").
  late final (String, int, bool)? remote = () {
    try {
      final cfg = rawConfig;
      final proto = RegExp(r'^\s*proto\s+(\w+)', multiLine: true)
              .firstMatch(cfg)
              ?.group(1) ??
          'udp';
      final m = RegExp(r'^\s*remote\s+(\S+)\s+(\d+)', multiLine: true)
          .firstMatch(cfg);
      if (m == null) return null;
      return (m.group(1)!, int.parse(m.group(2)!), proto.startsWith('tcp'));
    } catch (_) {
      return null;
    }
  }();

  /// Le profil contient-il un certificat client ?
  bool get certRequired => rawConfig.contains('<cert>');

  /// Mesure le temps de connexion TCP depuis l'appareil (ms).
  /// null = non mesurable (UDP), -1 = injoignable.
  Future<int?> measureLatency() async {
    final r = remote;
    if (r == null || !r.$3) return null;
    final sw = Stopwatch()..start();
    try {
      final sock = await Socket.connect(r.$1, r.$2,
          timeout: const Duration(milliseconds: 1800));
      sw.stop();
      sock.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  /// Chiffrement d'origine annonce par le serveur (ex. AES-128-CBC).
  String get serverCipher {
    final m = RegExp(r'^\s*cipher\s+(\S+)', multiLine: true)
        .firstMatch(rawConfig);
    return m?.group(1) ?? 'AES';
  }

  /// Profil renforce : AES-256-GCM / ChaCha20 en priorite (repli sur le
  /// chiffrement d'origine) et session limitee a 4 h.
  String get hardenedConfig {
    final fallback = serverCipher.toUpperCase();
    final ciphers = <String>[
      'AES-256-GCM',
      'CHACHA20-POLY1305',
      'AES-128-GCM',
      if (!['AES-256-GCM', 'CHACHA20-POLY1305', 'AES-128-GCM', 'AES']
          .contains(fallback))
        fallback,
    ];
    final lines = rawConfig.split(RegExp(r'\r?\n')).where((l) {
      final t = l.trimLeft();
      return !t.startsWith('data-ciphers') &&
          !t.startsWith('session-timeout') &&
          !t.startsWith('inactive') &&
          !t.startsWith('ignore-unknown-option');
    });
    return [
      // Options recentes ignorees si le moteur OpenVPN ne les connait pas.
      'ignore-unknown-option data-ciphers session-timeout',
      'data-ciphers ${ciphers.join(':')}',
      'session-timeout $maxSessionSeconds',
      // Secours pour les moteurs sans session-timeout : coupe apres 4 h
      // (seuil de trafic volontairement inatteignable, 1 To).
      'inactive $maxSessionSeconds 1000000000000',
      ...lines,
      '',
    ].join('\n');
  }

  String get uptimeLabel {
    final days = uptimeMs ~/ 86400000;
    if (days >= 1) return '$days d';
    final hours = uptimeMs ~/ 3600000;
    return '$hours h';
  }
}

class VpnGateApi {
  static const _urls = [
    'https://www.vpngate.net/api/iphone/',
    'http://www.vpngate.net/api/iphone/',
  ];

  static Future<List<VpnServer>> fetchServers() async {
    Object? lastError;
    for (final url in _urls) {
      try {
        final res = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 25));
        if (res.statusCode == 200) {
          final body = utf8.decode(res.bodyBytes, allowMalformed: true);
          final list = _parse(body);
          if (list.isNotEmpty) return list;
          lastError = 'empty';
        } else {
          lastError = 'HTTP ${res.statusCode}';
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('VPN Gate: $lastError');
  }

  static List<VpnServer> _parse(String body) {
    final seenIps = <String>{};
    final out = <VpnServer>[];
    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('*') || line.startsWith('#')) {
        continue;
      }
      final f = line.split(',');
      if (f.length < 15) continue;
      final cfg = f.last.trim();
      if (cfg.length < 100) continue;
      final ip = f[1];
      if (!seenIps.add(ip)) continue; // une IP = un serveur
      out.add(VpnServer(
        host: f[0],
        ip: ip,
        score: int.tryParse(f[2]) ?? 0,
        ping: int.tryParse(f[3]) ?? 0,
        speed: int.tryParse(f[4]) ?? 0,
        country: f[5],
        countryCode: f[6],
        sessions: int.tryParse(f[7]) ?? 0,
        uptimeMs: int.tryParse(f[8]) ?? 0,
        operator: f.length > 12 ? f[12] : '',
        configB64: cfg,
      ));
    }
    return out;
  }

  /// IP publique actuelle + pays (ipwho.is), repli sur ipify (IP seule).
  static Future<IpInfo?> currentIp() async {
    final nonce = DateTime.now().millisecondsSinceEpoch;
    try {
      final res = await http
          .get(Uri.parse('https://ipwho.is/?lang=${L.lang}&_=$nonce'),
              headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final j =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        if (j['success'] != false && j['ip'] != null) {
          final conn = j['connection'];
          return IpInfo(
            ip: j['ip'] as String,
            country: (j['country'] ?? '') as String,
            countryCode: (j['country_code'] ?? '') as String,
            city: (j['city'] ?? '') as String,
            isp: conn is Map ? (conn['isp'] ?? '').toString() : '',
          );
        }
      }
    } catch (_) {}
    try {
      final res = await http
          .get(Uri.parse('https://api.ipify.org?format=json&_=$nonce'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final ip =
            (jsonDecode(res.body) as Map<String, dynamic>)['ip'] as String?;
        if (ip != null) return IpInfo(ip: ip);
      }
    } catch (_) {}
    return null;
  }
}

class IpInfo {
  final String ip;
  final String country;
  final String countryCode;
  final String city;
  final String isp;
  const IpInfo({
    required this.ip,
    this.country = '',
    this.countryCode = '',
    this.city = '',
    this.isp = '',
  });

  String get place {
    final parts = [city, country].where((s) => s.isNotEmpty).toList();
    return parts.join(', ');
  }
}

String flagOf(String cc) {
  final c = cc.toUpperCase();
  if (c.length != 2 || c.codeUnits.any((u) => u < 65 || u > 90)) return '🌐';
  return String.fromCharCodes(c.codeUnits.map((u) => 0x1F1E6 + u - 65).toList());
}

String fmtDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}

String latencyLabel(VpnServer s, int? latency) {
  if (latency == -1) return L.t('unreachable');
  if (latency != null && latency > 0) return '$latency ms';
  return s.ping > 0 ? '~${s.ping} ms' : '?';
}

const _busyStages = {
  VPNStage.prepare,
  VPNStage.authenticating,
  VPNStage.connecting,
  VPNStage.authentication,
  VPNStage.wait_connection,
  VPNStage.vpn_generate_config,
  VPNStage.get_config,
  VPNStage.tcp_connect,
  VPNStage.udp_connect,
  VPNStage.assign_ip,
  VPNStage.resolve,
};

// ---------------------------------------------------------------------------
// Ecran principal
// ---------------------------------------------------------------------------

enum SortMode { best, score, speed, ping }

class ServerListPage extends StatefulWidget {
  const ServerListPage({super.key});

  @override
  State<ServerListPage> createState() => _ServerListPageState();
}

class _ServerListPageState extends State<ServerListPage>
    with WidgetsBindingObserver {
  static const maxShown = 50;

  List<VpnServer> _all = [];
  bool _loading = true;
  String? _error;
  String? _country; // null = tous
  SortMode _sort = SortMode.best;
  IpInfo? _myIp;
  bool _ipChecking = false;
  bool _ipFailed = false;
  bool _showWarning = true;
  bool _revealIp = false; // mode discret : IP masquee par defaut

  // Ping mesure depuis l'appareil : ip -> ms (-1 = injoignable).
  final Map<String, int> _latency = {};
  bool _measuring = false;
  int _measureRun = 0;

  // Verification : IP avant connexion + serveur choisi.
  IpInfo? _ipBefore;
  VpnServer? _target;

  // Moteur VPN integre.
  late final OpenVPN _vpn;
  VPNStage _stage = VPNStage.disconnected;
  VpnServer? _active;
  DateTime? _connectedAt;
  Timer? _sessionTimer;
  Timer? _tick;
  String? _notice;

  bool get _isConnected => _stage == VPNStage.connected;
  bool get _isBusy => _busyStages.contains(_stage);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vpn = OpenVPN(
      onVpnStatusChanged: _onVpnStatus,
      onVpnStageChanged: _onVpnStage,
    );
    _vpn.initialize(
      localizedDescription: 'Hopora VPN',
      lastStage: (stage) {
        if (!mounted) return;
        setState(() => _stage = stage);
        if (stage == VPNStage.connected) _armSession();
      },
      lastStatus: _onVpnStatus,
    );
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionTimer?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isConnected) _armSession(); // coupe si les 4 h sont depassees
      _refreshIp();
    }
  }

  // ----- Moteur VPN -----

  void _onVpnStatus(VpnStatus? s) {
    final on = s?.connectedOn;
    if (on != null && mounted && _connectedAt != on) {
      setState(() => _connectedAt = on);
      _armSession();
    }
  }

  void _onVpnStage(VPNStage stage, String raw) {
    if (!mounted) return;
    final was = _stage;
    setState(() {
      _stage = stage;
      if (stage == VPNStage.denied) _notice = L.t('vpn_denied');
      if (stage == VPNStage.error) _notice = L.t('vpn_error');
    });
    if (stage == VPNStage.connected) {
      _connectedAt ??= DateTime.now();
      _armSession();
      Future.delayed(const Duration(seconds: 2), _refreshIp);
    } else if (stage == VPNStage.disconnected) {
      _sessionTimer?.cancel();
      _tick?.cancel();
      _tick = null;
      _connectedAt = null;
      if (was == VPNStage.connected) {
        Future.delayed(const Duration(seconds: 2), _refreshIp);
      }
    }
  }

  /// Programme la coupure automatique a 4 h et le rafraichissement du compteur.
  void _armSession() {
    _sessionTimer?.cancel();
    final start = _connectedAt ?? DateTime.now();
    final left = const Duration(seconds: maxSessionSeconds) -
        DateTime.now().difference(start);
    if (left <= Duration.zero) {
      _endSession();
      return;
    }
    _sessionTimer = Timer(left, _endSession);
    _tick ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  void _endSession() {
    _vpn.disconnect();
    if (mounted) setState(() => _notice = L.t('session_over'));
  }

  Future<void> _connectTo(VpnServer s) async {
    // Ecran d'information et de consentement (exige par Google Play).
    if (!(prefs.getBool('vpn_consent') ?? false)) {
      final ok = await _showConsent();
      if (ok != true) return;
      await prefs.setBool('vpn_consent', true);
    }
    // IP de reference prise avant de se connecter.
    final before = _isConnected ? _ipBefore : await VpnGateApi.currentIp() ?? _myIp;
    if (!mounted) return;
    setState(() {
      _ipBefore = before;
      _target = s;
      _notice = null;
    });
    await AdsManager.showThen(() async {
      if (_isConnected || _isBusy) {
        _vpn.disconnect();
        await Future.delayed(const Duration(milliseconds: 800));
      }
      if (!mounted) return;
      setState(() {
        _active = s;
        _connectedAt = null;
        _stage = VPNStage.prepare;
      });
      try {
        // Pas d'await : si Android demande l'autorisation VPN, l'appel
        // ne renvoie jamais de reponse ; la connexion reprend apres accord.
        unawaited(_vpn
            .connect(
              s.hardenedConfig,
              '${s.country} · Hopora',
              username: 'vpn',
              password: 'vpn',
              certIsRequired: s.certRequired,
            )
            .catchError((_) {
          if (mounted) setState(() => _notice = L.t('vpn_error'));
        }));
      } catch (_) {
        if (mounted) setState(() => _notice = L.t('vpn_error'));
      }
    });
  }

  void _disconnect() {
    _vpn.disconnect();
    _sessionTimer?.cancel();
  }

  Future<bool?> _showConsent() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.vpn_lock),
        title: Text(L.t('consent_title')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(L.t('consent_body')),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(privacyUrl),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.policy_outlined),
                label: Text(L.t('privacy')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('consent_accept'))),
        ],
      ),
    );
  }

  // ----- Donnees -----

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ipFuture = VpnGateApi.currentIp();
    try {
      final servers = await VpnGateApi.fetchServers();
      if (!mounted) return;
      setState(() {
        _all = servers;
        _latency.clear();
      });
      if (!_isConnected) _measureFastest();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = L.t('error_load'));
    }
    final ip = await ipFuture;
    if (!mounted) return;
    setState(() {
      _myIp = ip;
      _ipFailed = ip == null;
      _loading = false;
    });
  }

  /// Mesure le ping reel (depuis le telephone) des 40 serveurs les plus
  /// rapides, par paquets de 10, pour trouver le meilleur pour l'utilisateur.
  Future<void> _measureFastest() async {
    final run = ++_measureRun;
    final candidates = [..._all.where((s) => s.remote?.$3 == true)]
      ..sort((a, b) => b.speed.compareTo(a.speed));
    final top = candidates.take(40).toList();
    setState(() => _measuring = true);
    for (var i = 0; i < top.length; i += 10) {
      final batch = top.skip(i).take(10).toList();
      final results = await Future.wait(batch.map((s) => s.measureLatency()));
      if (!mounted || run != _measureRun) return;
      setState(() {
        for (var j = 0; j < batch.length; j++) {
          final r = results[j];
          if (r != null) _latency[batch[j].ip] = r;
        }
      });
    }
    if (mounted && run == _measureRun) setState(() => _measuring = false);
  }

  /// Note de rapidite : debit divise par la latence (mesuree si possible).
  double _quality(VpnServer s) {
    final l = _latency[s.ip];
    if (l == -1) return -1; // injoignable depuis cet appareil
    final ping = (l != null && l > 0)
        ? l.toDouble()
        : (s.ping > 0 ? s.ping + 150.0 : 400.0); // non mesure : penalise
    return s.speedMbps / (1 + ping / 40);
  }

  List<VpnServer> get _filtered => _all
      .where((s) => _country == null || s.countryCode == _country)
      .toList();

  VpnServer? get _fastest {
    VpnServer? best;
    var bestQ = -1.0;
    for (final s in _filtered) {
      final q = _quality(s);
      if (q > bestQ) {
        bestQ = q;
        best = s;
      }
    }
    return bestQ > 0 ? best : null;
  }

  Future<void> _refreshIp() async {
    if (_ipChecking || !mounted) return;
    setState(() => _ipChecking = true);
    final ip = await VpnGateApi.currentIp();
    if (!mounted) return;
    setState(() {
      _ipChecking = false;
      _ipFailed = ip == null;
      if (ip != null) _myIp = ip;
    });
  }

  List<VpnServer> get _shown {
    final list = _filtered;
    switch (_sort) {
      case SortMode.best:
        list.sort((a, b) => _quality(b).compareTo(_quality(a)));
      case SortMode.score:
        list.sort((a, b) => b.score.compareTo(a.score));
      case SortMode.speed:
        list.sort((a, b) => b.speed.compareTo(a.speed));
      case SortMode.ping:
        int p(VpnServer s) {
          final l = _latency[s.ip];
          if (l != null && l > 0) return l;
          if (l == -1) return 99999;
          return s.ping > 0 ? s.ping + 150 : 9999;
        }
        list.sort((a, b) => p(a).compareTo(p(b)));
    }
    return list.take(maxShown).toList();
  }

  List<MapEntry<String, int>> get _countries {
    final counts = <String, int>{};
    for (final s in _all) {
      counts[s.countryCode] = (counts[s.countryCode] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  // ----- Interface -----

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final discreet = prefs.getBool('discreet') ?? true;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: Text(L.t('discreet_mode')),
                  subtitle: Text(L.t('discreet_desc')),
                  value: discreet,
                  onChanged: (v) async {
                    await prefs.setBool('discreet', v);
                    try {
                      await _secureChannel.invokeMethod('set', v);
                    } catch (_) {}
                    setSheet(() {});
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.policy_outlined),
                  title: Text(L.t('privacy')),
                  onTap: () => launchUrl(Uri.parse(privacyUrl),
                      mode: LaunchMode.externalApplication),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final fastest = _fastest;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hopora VPN'),
        actions: [
          PopupMenuButton<SortMode>(
            tooltip: L.t('sort'),
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (m) => setState(() => _sort = m),
            itemBuilder: (_) => [
              PopupMenuItem(value: SortMode.best, child: Text(L.t('sort_best'))),
              PopupMenuItem(value: SortMode.speed, child: Text(L.t('sort_speed'))),
              PopupMenuItem(value: SortMode.ping, child: Text(L.t('sort_ping'))),
              PopupMenuItem(value: SortMode.score, child: Text(L.t('sort_score'))),
            ],
          ),
          IconButton(
            tooltip: L.t('refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            tooltip: L.t('settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _loading && _all.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _all.isEmpty
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      _VpnCard(
                        stage: _stage,
                        active: _active,
                        fastest: fastest,
                        latency: fastest == null ? null : _latency[fastest.ip],
                        measuring: _measuring,
                        connectedAt: _connectedAt,
                        onQuickConnect:
                            fastest == null ? null : () => _connectTo(fastest),
                        onDisconnect: _disconnect,
                      ),
                      if (_notice != null)
                        _NoticeCard(
                          text: _notice!,
                          onClose: () => setState(() => _notice = null),
                        ),
                      _IpCard(
                        ip: _myIp,
                        before: _ipBefore,
                        target: _target,
                        checking: _ipChecking || (_loading && _myIp == null),
                        failed: _ipFailed,
                        masked: !_revealIp,
                        onToggleMask: () =>
                            setState(() => _revealIp = !_revealIp),
                        onRefresh: _refreshIp,
                      ),
                      if (_showWarning)
                        _NoticeCard(
                          text: L.t('warning'),
                          info: true,
                          onClose: () => setState(() => _showWarning = false),
                        ),
                      _CountryChips(
                        countries: _countries,
                        selected: _country,
                        onSelected: (c) => setState(() => _country = c),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          L.t('servers_count',
                                  {'n': shown.length, 'total': _all.length}) +
                              (_measuring ? L.t('measuring') : ''),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      for (final s in shown)
                        _ServerTile(
                          server: s,
                          latency: _latency[s.ip],
                          isFastest: identical(s, fastest),
                          isActive: _isConnected && identical(s, _active),
                          onTap: () => _openSheet(s),
                        ),
                    ],
                  ),
                ),
    );
  }

  void _openSheet(VpnServer s) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ConnectSheet(
        server: s,
        latency: _latency[s.ip],
        switching: _isConnected || _isBusy,
        onConnect: () {
          Navigator.pop(ctx);
          _connectTo(s);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _VpnCard extends StatelessWidget {
  final VPNStage stage;
  final VpnServer? active;
  final VpnServer? fastest;
  final int? latency;
  final bool measuring;
  final DateTime? connectedAt;
  final VoidCallback? onQuickConnect;
  final VoidCallback onDisconnect;
  const _VpnCard({
    required this.stage,
    required this.active,
    required this.fastest,
    required this.latency,
    required this.measuring,
    required this.connectedAt,
    required this.onQuickConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final connected = stage == VPNStage.connected;
    final busy = _busyStages.contains(stage);
    const ok = Color(0xFF1E8E3E);

    final bg = connected ? ok : cs.primary;
    const fg = Colors.white;
    final s = (connected || busy) ? active : fastest;

    String label;
    String? sub;
    if (connected) {
      label = L.t('protected_via', {'country': active?.country ?? ''});
      final since = connectedAt == null
          ? Duration.zero
          : DateTime.now().difference(connectedAt!);
      sub = '${L.t('connected_for', {'time': fmtDuration(since)})}\n'
          '${L.t('session_left', {'time': fmtDuration(const Duration(seconds: maxSessionSeconds) - since)})}';
    } else if (busy) {
      label = L.t('connecting');
      sub = s?.country;
    } else {
      label = s?.country ?? L.t('searching');
      sub = s == null
          ? null
          : '${s.speedMbps.toStringAsFixed(0)} Mb/s · ping ${latencyLabel(s, latency)}';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!connected && !busy)
              Text(L.t('fastest'),
                  style: tt.labelLarge
                      ?.copyWith(color: fg.withValues(alpha: 0.85))),
            const SizedBox(height: 6),
            Row(
              children: [
                connected
                    ? const Icon(Icons.verified_user, color: fg, size: 34)
                    : Text(s?.flag ?? '🌐', style: const TextStyle(fontSize: 32)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: tt.titleLarge?.copyWith(
                              color: fg, fontWeight: FontWeight.w600)),
                      if (sub != null)
                        Text(sub,
                            style: tt.bodyMedium
                                ?.copyWith(color: fg.withValues(alpha: 0.92))),
                    ],
                  ),
                ),
                if (busy || (measuring && !connected))
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: fg),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: fg,
                foregroundColor: bg,
                minimumSize: const Size.fromHeight(52),
                textStyle:
                    tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              onPressed: (connected || busy) ? onDisconnect : onQuickConnect,
              icon: Icon((connected || busy) ? Icons.power_settings_new : Icons.bolt),
              label: Text((connected || busy)
                  ? L.t('disconnect')
                  : L.t('quick_connect')),
            ),
            if (!connected && !busy) ...[
              const SizedBox(height: 8),
              Text(L.t('session_note'),
                  textAlign: TextAlign.center,
                  style: tt.bodySmall
                      ?.copyWith(color: fg.withValues(alpha: 0.85))),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final String text;
  final bool info;
  final VoidCallback onClose;
  const _NoticeCard({required this.text, required this.onClose, this.info = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = info ? cs.tertiaryContainer : cs.errorContainer;
    final fg = info ? cs.onTertiaryContainer : cs.onErrorContainer;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(info ? Icons.info_outline : Icons.error_outline,
                  color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(text, style: TextStyle(color: fg)),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: fg),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

enum IpStatus { unknown, changed, viaServer, unchanged }

class _IpCard extends StatelessWidget {
  final IpInfo? ip;
  final IpInfo? before;
  final VpnServer? target;
  final bool checking;
  final bool failed;
  final bool masked;
  final VoidCallback onToggleMask;
  final VoidCallback onRefresh;
  const _IpCard({
    required this.ip,
    required this.before,
    required this.target,
    required this.checking,
    required this.failed,
    required this.masked,
    required this.onToggleMask,
    required this.onRefresh,
  });

  IpStatus get status {
    final now = ip;
    final b = before;
    if (now == null || b == null || target == null) return IpStatus.unknown;
    if (now.ip == target!.ip) return IpStatus.viaServer;
    if (now.ip != b.ip) return IpStatus.changed;
    return IpStatus.unchanged;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    const ok = Color(0xFF1E8E3E);
    const warn = Color(0xFFE37400);

    final st = status;
    final (Color bg, Color fg, IconData icon, String headline) = switch (st) {
      IpStatus.viaServer => (
          ok.withValues(alpha: 0.16),
          cs.onSurface,
          Icons.verified_user,
          L.t('ip_changed_via', {'country': target!.country})
        ),
      IpStatus.changed => (
          ok.withValues(alpha: 0.16),
          cs.onSurface,
          Icons.check_circle,
          L.t('ip_changed')
        ),
      IpStatus.unchanged => (
          warn.withValues(alpha: 0.16),
          cs.onSurface,
          Icons.warning_amber_rounded,
          L.t('ip_unchanged')
        ),
      IpStatus.unknown => (
          cs.primaryContainer,
          cs.onPrimaryContainer,
          Icons.public,
          L.t('your_ip')
        ),
    };
    final iconColor = switch (st) {
      IpStatus.viaServer || IpStatus.changed => ok,
      IpStatus.unchanged => warn,
      IpStatus.unknown => cs.onPrimaryContainer,
    };

    final now = ip;
    final compare = before != null && st != IpStatus.unknown;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(headline,
                      style: tt.titleMedium
                          ?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: masked ? L.t('show_ip') : L.t('hide_ip'),
                  icon: Icon(masked ? Icons.visibility_off : Icons.visibility,
                      color: fg),
                  onPressed: onToggleMask,
                ),
                checking
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        tooltip: L.t('check_ip'),
                        icon: Icon(Icons.refresh, color: fg),
                        onPressed: onRefresh,
                      ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 36, end: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (now == null)
                    Text(failed ? L.t('ip_failed') : L.t('searching'),
                        style: TextStyle(color: fg))
                  else ...[
                    if (compare)
                      _IpLine(
                          label: L.t('before'),
                          info: before!,
                          color: fg,
                          masked: masked,
                          strike: st != IpStatus.unchanged),
                    _IpLine(
                        label: compare ? L.t('now') : L.t('ip'),
                        info: now,
                        color: fg,
                        masked: masked,
                        bold: true),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IpLine extends StatelessWidget {
  final String label;
  final IpInfo info;
  final Color color;
  final bool bold;
  final bool strike;
  final bool masked;
  const _IpLine({
    required this.label,
    required this.info,
    required this.color,
    this.bold = false,
    this.strike = false,
    this.masked = false,
  });

  /// Mode discret : 83.•••.•••.12 et seulement le pays.
  static String maskIp(String ip) {
    final p = ip.split('.');
    if (p.length == 4) return '${p[0]}.•••.•••.${p[3]}';
    final v6 = ip.split(':');
    return v6.length > 2 ? '${v6.first}:•••:${v6.last}' : '•••';
  }

  @override
  Widget build(BuildContext context) {
    final place = masked ? info.country : info.place;
    final shownIp = masked ? maskIp(info.ip) : info.ip;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label,
                style: TextStyle(color: color.withValues(alpha: 0.75))),
          ),
          Expanded(
            child: Text(
              '${info.countryCode.isNotEmpty ? '${flagOf(info.countryCode)} ' : ''}'
              '$shownIp${place.isNotEmpty ? '  ·  $place' : ''}',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                color: color,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
                decoration: strike ? TextDecoration.lineThrough : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountryChips extends StatelessWidget {
  final List<MapEntry<String, int>> countries;
  final String? selected;
  final ValueChanged<String?> onSelected;
  const _CountryChips(
      {required this.countries, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: ChoiceChip(
              label: Text(L.t('all_countries')),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final c in countries)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text('${flagOf(c.key)} ${c.key} (${c.value})'),
                selected: selected == c.key,
                onSelected: (_) => onSelected(c.key),
              ),
            ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final VpnServer server;
  final int? latency;
  final bool isFastest;
  final bool isActive;
  final VoidCallback onTap;
  const _ServerTile({
    required this.server,
    required this.latency,
    required this.isFastest,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = server;
    final cs = Theme.of(context).colorScheme;
    final dead = latency == -1;
    Widget trailing;
    if (isActive) {
      trailing = const Icon(Icons.verified_user, color: Color(0xFF1E8E3E));
    } else if (isFastest) {
      trailing = Chip(
        label: Text(L.t('fastest_badge')),
        visualDensity: VisualDensity.compact,
        backgroundColor: cs.primaryContainer,
        side: BorderSide.none,
      );
    } else {
      trailing = const Icon(Icons.chevron_right);
    }
    return Opacity(
      opacity: dead ? 0.45 : 1,
      child: ListTile(
        onTap: onTap,
        leading: Text(s.flag, style: const TextStyle(fontSize: 30)),
        title: Text(s.country),
        subtitle: Text(
          '${s.speedMbps.toStringAsFixed(1)} Mb/s · '
          'ping ${latencyLabel(s, latency)} · '
          '${L.t('users', {'n': s.sessions})}',
        ),
        trailing: trailing,
      ),
    );
  }
}

class _ConnectSheet extends StatelessWidget {
  final VpnServer server;
  final int? latency;
  final bool switching;
  final VoidCallback onConnect;
  const _ConnectSheet({
    required this.server,
    required this.latency,
    required this.switching,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final s = server;
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(s.flag, style: const TextStyle(fontSize: 40)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.country, style: tt.titleLarge),
                      Text(s.ip,
                          textDirection: TextDirection.ltr,
                          style: tt.titleMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Info(L.t('speed'), '${s.speedMbps.toStringAsFixed(1)} Mb/s'),
            _Info(L.t('ping_device'), latencyLabel(s, latency)),
            _Info(L.t('encryption'), L.t('enc_value', {'c': s.serverCipher})),
            _Info('👥', L.t('users', {'n': s.sessions})),
            _Info(L.t('online_since'), s.uptimeLabel),
            const SizedBox(height: 12),
            Text(L.t('session_note'), style: tt.bodyMedium),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.vpn_lock),
                label: Text(
                    switching ? L.t('switch_server') : L.t('connect')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  final String label;
  final String value;
  const _Info(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(L.t('error_hint'), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(L.t('retry'))),
          ],
        ),
      ),
    );
  }
}
