import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

  const VpnServer({
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

  String get flag {
    final cc = countryCode.toUpperCase();
    if (cc.length != 2 ||
        cc.codeUnits.any((c) => c < 65 || c > 90)) {
      return '🌐';
    }
    return String.fromCharCodes(
        cc.codeUnits.map((c) => 0x1F1E6 + c - 65).toList());
  }

  String get rawConfig =>
      utf8.decode(base64.decode(configB64), allowMalformed: true);

  /// Chiffrement d'origine annonce par le serveur (ex. AES-128-CBC).
  String get serverCipher {
    final m = RegExp(r'^\s*cipher\s+(\S+)', multiLine: true)
        .firstMatch(rawConfig);
    return m?.group(1) ?? 'AES';
  }

  /// Profil renforce : demande en priorite AES-256-GCM / ChaCha20,
  /// avec repli sur le chiffrement d'origine pour rester compatible.
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
    final lines = rawConfig
        .split(RegExp(r'\r?\n'))
        .where((l) => !l.trimLeft().startsWith('data-ciphers'))
        .toList();
    return [
      '# Hopora VPN - chiffrement renforce',
      'data-ciphers ${ciphers.join(':')}',
      ...lines,
    ].join('\n');
  }

  String get uptimeLabel {
    final days = uptimeMs ~/ 86400000;
    if (days >= 1) return '$days j';
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
          lastError = 'Liste vide';
        } else {
          lastError = 'HTTP ${res.statusCode}';
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Impossible de joindre VPN Gate ($lastError)');
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
          .get(Uri.parse('https://ipwho.is/?lang=fr&_=$nonce'),
              headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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

// ---------------------------------------------------------------------------
// Ecran principal
// ---------------------------------------------------------------------------

enum SortMode { score, speed, ping }

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
  SortMode _sort = SortMode.score;
  IpInfo? _myIp;
  bool _ipChecking = false;
  bool _ipFailed = false;
  bool _showWarning = true;

  // Pour la verification : IP avant connexion + serveur choisi.
  IpInfo? _ipBefore;
  VpnServer? _target;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Au retour d'OpenVPN, on reverifie l'IP automatiquement.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _target != null) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _refreshIp();
      });
    }
  }

  Future<void> _beforeConnect(VpnServer s) async {
    final current = await VpnGateApi.currentIp() ?? _myIp;
    if (!mounted) return;
    setState(() {
      _ipBefore = current;
      _target = s;
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ipFuture = VpnGateApi.currentIp();
    try {
      final servers = await VpnGateApi.fetchServers();
      if (!mounted) return;
      setState(() => _all = servers);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    final ip = await ipFuture;
    if (!mounted) return;
    setState(() {
      _myIp = ip;
      _ipFailed = ip == null;
      _loading = false;
    });
  }

  Future<void> _refreshIp() async {
    if (_ipChecking) return;
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
    final list = _all
        .where((s) => _country == null || s.countryCode == _country)
        .toList();
    switch (_sort) {
      case SortMode.score:
        list.sort((a, b) => b.score.compareTo(a.score));
      case SortMode.speed:
        list.sort((a, b) => b.speed.compareTo(a.speed));
      case SortMode.ping:
        list.sort((a, b) {
          final pa = a.ping <= 0 ? 9999 : a.ping;
          final pb = b.ping <= 0 ? 9999 : b.ping;
          return pa.compareTo(pb);
        });
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

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hopora VPN'),
        actions: [
          PopupMenuButton<SortMode>(
            tooltip: 'Trier',
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (m) => setState(() => _sort = m),
            itemBuilder: (_) => const [
              PopupMenuItem(value: SortMode.score, child: Text('Meilleur score')),
              PopupMenuItem(value: SortMode.speed, child: Text('Plus rapides')),
              PopupMenuItem(value: SortMode.ping, child: Text('Ping le plus bas')),
            ],
          ),
          IconButton(
            tooltip: 'Actualiser',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
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
                      _IpCard(
                        ip: _myIp,
                        before: _ipBefore,
                        target: _target,
                        checking: _ipChecking || (_loading && _myIp == null),
                        failed: _ipFailed,
                        onRefresh: _refreshIp,
                      ),
                      if (_showWarning)
                        _WarningCard(
                            onClose: () => setState(() => _showWarning = false)),
                      _CountryChips(
                        countries: _countries,
                        selected: _country,
                        onSelected: (c) => setState(() => _country = c),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          '${shown.length} serveurs (IP différentes) · ${_all.length} disponibles',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      for (final s in shown)
                        _ServerTile(server: s, onTap: () => _openSheet(s)),
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
      builder: (_) => _ConnectSheet(server: s, onBeforeConnect: _beforeConnect),
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

enum IpStatus { unknown, changed, viaServer, unchanged }

class _IpCard extends StatelessWidget {
  final IpInfo? ip;
  final IpInfo? before;
  final VpnServer? target;
  final bool checking;
  final bool failed;
  final VoidCallback onRefresh;
  const _IpCard({
    required this.ip,
    required this.before,
    required this.target,
    required this.checking,
    required this.failed,
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
          'IP changée : vous passez par le serveur ${target!.country}'
        ),
      IpStatus.changed => (
          ok.withValues(alpha: 0.16),
          cs.onSurface,
          Icons.check_circle,
          'IP changée'
        ),
      IpStatus.unchanged => (
          warn.withValues(alpha: 0.16),
          cs.onSurface,
          Icons.warning_amber_rounded,
          'IP inchangée : le VPN n\'est pas encore actif'
        ),
      IpStatus.unknown => (
          cs.primaryContainer,
          cs.onPrimaryContainer,
          Icons.public,
          'Votre IP actuelle'
        ),
    };
    final iconColor = switch (st) {
      IpStatus.viaServer || IpStatus.changed => ok,
      IpStatus.unchanged => warn,
      IpStatus.unknown => cs.onPrimaryContainer,
    };

    final now = ip;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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
                checking
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        tooltip: 'Vérifier mon IP',
                        icon: Icon(Icons.refresh, color: fg),
                        onPressed: onRefresh,
                      ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 36, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (now == null)
                    Text(failed ? 'Impossible de vérifier l\'IP pour le moment.' : 'Recherche…',
                        style: TextStyle(color: fg))
                  else ...[
                    if (before != null && st != IpStatus.unknown)
                      _IpLine(label: 'Avant', info: before!, color: fg, strike: st != IpStatus.unchanged),
                    _IpLine(
                        label: before != null && st != IpStatus.unknown ? 'Maintenant' : 'IP',
                        info: now,
                        color: fg,
                        bold: true),
                  ],
                  if (st == IpStatus.unchanged) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Ouvrez OpenVPN for Android, touchez le profil Hopora pour l\'activer, '
                      'puis revenez ici : l\'IP est revérifiée automatiquement.',
                      style: tt.bodySmall?.copyWith(color: fg),
                    ),
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
  const _IpLine({
    required this.label,
    required this.info,
    required this.color,
    this.bold = false,
    this.strike = false,
  });

  @override
  Widget build(BuildContext context) {
    final place = info.place;
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
              '${info.ip}${place.isNotEmpty ? '  ·  $place' : ''}',
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

class _WarningCard extends StatelessWidget {
  final VoidCallback onClose;
  const _WarningCard({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(Icons.info_outline, color: cs.onTertiaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Ces serveurs sont prêtés par des bénévoles du projet VPN Gate. '
                'Ne les utilisez pas pour la banque ou des données sensibles.',
                style: TextStyle(color: cs.onTertiaryContainer),
              ),
            ),
            IconButton(
              tooltip: 'Masquer',
              icon: Icon(Icons.close, color: cs.onTertiaryContainer),
              onPressed: onClose,
            ),
          ],
        ),
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

  String _flag(String cc) => VpnServer(
        host: '',
        ip: '',
        score: 0,
        ping: 0,
        speed: 0,
        country: '',
        countryCode: cc,
        sessions: 0,
        uptimeMs: 0,
        operator: '',
        configB64: '',
      ).flag;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('Tous les pays'),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final c in countries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('${_flag(c.key)} ${c.key} (${c.value})'),
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
  final VoidCallback onTap;
  const _ServerTile({required this.server, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = server;
    return ListTile(
      onTap: onTap,
      leading: Text(s.flag, style: const TextStyle(fontSize: 30)),
      title: Text('${s.country} · ${s.ip}'),
      subtitle: Text(
        '${s.speedMbps.toStringAsFixed(1)} Mb/s · '
        'ping ${s.ping > 0 ? '${s.ping} ms' : '?'} · '
        '${s.sessions} connectés',
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _ConnectSheet extends StatefulWidget {
  final VpnServer server;
  final Future<void> Function(VpnServer) onBeforeConnect;
  const _ConnectSheet({required this.server, required this.onBeforeConnect});

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  bool _busy = false;
  String? _status;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    await widget.onBeforeConnect(widget.server);
    await AdsManager.showThen(_openProfile);
  }

  Future<void> _openProfile() async {
    final s = widget.server;
    try {
      final dir = await getTemporaryDirectory();
      final safeName = s.host.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file =
          File('${dir.path}/Hopora_${s.countryCode}_$safeName.ovpn');
      await file.writeAsString(s.hardenedConfig, flush: true);
      final result = await OpenFilex.open(
        file.path,
        type: 'application/x-openvpn-profile',
      );
      if (!mounted) return;
      if (result.type == ResultType.noAppToOpen) {
        setState(() => _status = 'missing');
      } else if (result.type != ResultType.done) {
        setState(() => _status = 'Erreur : ${result.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installOpenVpn() async {
    final market = Uri.parse('market://details?id=de.blinkt.openvpn');
    final web = Uri.parse(
        'https://play.google.com/store/apps/details?id=de.blinkt.openvpn');
    try {
      final ok =
          await launchUrl(market, mode: LaunchMode.externalApplication);
      if (!ok) await launchUrl(web, mode: LaunchMode.externalApplication);
    } catch (_) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.server;
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
                      SelectableText(s.ip, style: tt.titleMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Info('Vitesse', '${s.speedMbps.toStringAsFixed(1)} Mb/s'),
            _Info('Ping', s.ping > 0 ? '${s.ping} ms' : 'inconnu'),
            _Info('Chiffrement',
                'AES-256-GCM prioritaire (repli ${s.serverCipher})'),
            _Info('Utilisateurs connectés', '${s.sessions}'),
            _Info('En ligne depuis', s.uptimeLabel),
            if (s.operator.isNotEmpty) _Info('Opérateur', s.operator),
            const SizedBox(height: 16),
            Text(
              '1. Appuyez sur « Se connecter » : le serveur s\'ouvre dans OpenVPN for Android.\n'
              '2. Validez l\'import (coche en haut à droite).\n'
              '3. Touchez le profil pour vous connecter, puis revenez dans Hopora : votre IP est vérifiée automatiquement.',
              style: tt.bodyMedium,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.vpn_lock),
                label: const Text('Se connecter'),
              ),
            ),
            if (_status == 'missing') ...[
              const SizedBox(height: 12),
              Text(
                'L\'appli gratuite « OpenVPN for Android » est nécessaire pour établir la connexion.',
                style: tt.bodyMedium,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _installOpenVpn,
                  icon: const Icon(Icons.download),
                  label: const Text('Installer OpenVPN for Android'),
                ),
              ),
            ] else if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
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
          Flexible(child: Text(value, textAlign: TextAlign.right)),
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
            const Text(
              'Vérifiez votre connexion Internet. Si vous êtes déjà connecté à un VPN, '
              'déconnectez-le puis réessayez.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}
