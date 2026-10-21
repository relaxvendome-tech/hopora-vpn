// Mode Tor de Hopora : ecran, pilotage du service natif et bascule
// automatique vers les ponts anti-censure (Snowflake, obfs4, meek).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'main.dart';

/// Pont vers le service Android TorVpnService.
class TorCtl {
  static const _ch = MethodChannel('hopora/tor');

  static Future<Map<String, dynamic>> status() async {
    try {
      final m = await _ch.invokeMethod<Map>('status');
      return Map<String, dynamic>.from(m ?? const {});
    } catch (_) {
      return {};
    }
  }

  static Future<void> start(String transport) async {
    try {
      await _ch.invokeMethod(
          'start', {'transport': transport, 'notif': L.t('tor_notif')});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<void> transport(String t) async {
    try {
      await _ch.invokeMethod('transport', {'transport': t});
    } catch (_) {}
  }

  static Future<void> newIdentity() async {
    try {
      await _ch.invokeMethod('newnym');
    } catch (_) {}
  }

  /// Requete HTTPS envoyee a travers Tor (DNS resolu par Tor).
  static Future<String?> fetch(String url) async {
    try {
      return await _ch.invokeMethod<String>('fetch', {'url': url});
    } catch (_) {
      return null;
    }
  }

  static Future<void> stopIfRunning() async {
    final s = (await status())['state'];
    if (s == 'on' || s == 'starting' || s == 'permission') {
      await stop();
      await Future.delayed(const Duration(milliseconds: 800));
    }
  }
}

// ---------------------------------------------------------------------------
// Accueil : mode Rapide / mode Tor
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Le mode Rapide (liste VPN Gate + publicite) n'est charge que s'il est
  // ouvert : en mode Tor, l'appli ne contacte ni VPN Gate ni la regie.
  late int _tab = prefs.getString('mode') == 'tor' ? 1 : 0;
  final Set<int> _built = {};

  @override
  Widget build(BuildContext context) {
    _built.add(_tab);
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          _built.contains(0) ? const ServerListPage() : const SizedBox.shrink(),
          _built.contains(1) ? const TorPage() : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          prefs.setString('mode', i == 1 ? 'tor' : 'fast');
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.bolt_outlined),
            selectedIcon: const Icon(Icons.bolt),
            label: L.t('tab_fast'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.security_outlined),
            selectedIcon: const Icon(Icons.security),
            label: L.t('tab_tor'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ecran Tor
// ---------------------------------------------------------------------------

const _methods = ['auto', 'direct', 'snowflake', 'obfs4', 'meek'];
const _chain = ['direct', 'snowflake', 'obfs4', 'meek'];

String _methodLabel(String m) => switch (m) {
      'auto' => L.t('tor_auto'),
      'direct' => L.t('tor_direct'),
      'snowflake' => 'Snowflake',
      'obfs4' => 'obfs4',
      'meek' => 'meek',
      _ => m,
    };

String _methodDesc(String m) => switch (m) {
      'auto' => L.t('tor_auto_desc'),
      'direct' => L.t('tor_direct_desc'),
      'snowflake' => L.t('tor_snowflake_desc'),
      'obfs4' => L.t('tor_obfs4_desc'),
      'meek' => L.t('tor_meek_desc'),
      _ => '',
    };

/// Delai accorde a chaque methode avant de passer a la suivante (secondes).
int _baseTimeout(String t) => switch (t) {
      'direct' => 30,
      'obfs4' => 60,
      _ => 120,
    };

class TorPage extends StatefulWidget {
  const TorPage({super.key});

  @override
  State<TorPage> createState() => _TorPageState();
}

class _TorPageState extends State<TorPage> with WidgetsBindingObserver {
  String _method = prefs.getString('tor_method') ?? 'auto';

  String _state = 'off';
  int _progress = 0;
  String _transport = 'direct';
  int _since = 0;
  int _phaseAt = 0;

  bool _driving = false; // l'utilisateur a demande la connexion
  List<String> _plan = [];
  int _planIdx = 0;
  DateTime _lastSwitch = DateTime.fromMillisecondsSinceEpoch(0);

  String? _notice;
  bool _noticeIsError = false;

  bool _checking = false;
  bool? _isTor;
  IpInfo? _exit;

  Timer? _poll;

  bool get _on => _state == 'on';
  bool get _busy => _state == 'starting' || _state == 'permission';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final m = await TorCtl.status();
    if (!mounted || m.isEmpty) return;
    final prev = _state;
    final st = (m['state'] ?? 'off') as String;
    setState(() {
      _state = st;
      _progress = (m['progress'] as num?)?.toInt() ?? 0;
      _transport = (m['transport'] ?? 'direct') as String;
      _since = (m['since'] as num?)?.toInt() ?? 0;
      _phaseAt = (m['phaseStartedAt'] as num?)?.toInt() ?? 0;
    });

    if (st == 'on' && prev != 'on') {
      _driving = false;
      prefs.setString('tor_last_ok', _transport);
      setState(() => _notice = null);
      _check();
    } else if (st == 'off' && prev == 'on') {
      setState(() {
        _isTor = null;
        _exit = null;
      });
    }

    if (!_driving) return;
    if (st == 'denied') {
      _driving = false;
      _setNotice(L.t('vpn_denied'), error: true);
    } else if (st == 'error') {
      _driving = false;
      _setNotice(L.t('tor_failed'), error: true);
    } else if (st == 'starting') {
      _watchdog();
    }
  }

  /// Bascule automatique : si une methode n'aboutit pas a temps, on passe a
  /// la suivante (Tor bloque ? -> Snowflake -> obfs4 -> meek).
  void _watchdog() {
    if (_phaseAt == 0) return;
    if (DateTime.now().difference(_lastSwitch).inSeconds < 5) return;
    final elapsed =
        (DateTime.now().millisecondsSinceEpoch - _phaseAt) ~/ 1000;
    var limit = _baseTimeout(_transport);
    if (_progress >= 10) limit += 60; // relais ou pont joint : on patiente
    if (_progress >= 50) limit += 60;
    if (elapsed < limit) return;

    if (_planIdx + 1 < _plan.length) {
      _planIdx++;
      final next = _plan[_planIdx];
      _lastSwitch = DateTime.now();
      TorCtl.transport(next);
      _setNotice(L.t('tor_trying', {'m': _methodLabel(next)}));
    } else {
      _driving = false;
      TorCtl.stop();
      _setNotice(L.t('tor_failed'), error: true);
    }
  }

  void _setNotice(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = text;
      _noticeIsError = error;
    });
  }

  List<String> _buildPlan() {
    if (_method != 'auto') return [_method];
    final last = prefs.getString('tor_last_ok');
    final plan = <String>[];
    if (last != null && _chain.contains(last)) plan.add(last);
    for (final t in _chain) {
      if (!plan.contains(t)) plan.add(t);
    }
    return plan;
  }

  Future<void> _connect() async {
    if (!(prefs.getBool('tor_consent') ?? false)) {
      final ok = await _showConsent();
      if (ok != true) return;
      await prefs.setBool('tor_consent', true);
    }
    // Un seul VPN a la fois : le mode Rapide est coupe.
    if (stopFastVpn != null) {
      stopFastVpn!();
      await Future.delayed(const Duration(milliseconds: 600));
    }
    _plan = _buildPlan();
    _planIdx = 0;
    _driving = true;
    _lastSwitch = DateTime.now();
    setState(() {
      _notice = null;
      _isTor = null;
      _exit = null;
      _state = 'starting';
      _progress = 0;
    });
    await TorCtl.start(_plan.first);
  }

  void _disconnect() {
    _driving = false;
    TorCtl.stop();
    setState(() {
      _notice = null;
      _isTor = null;
      _exit = null;
    });
  }

  Future<void> _selectMethod(String m) async {
    setState(() => _method = m);
    await prefs.setString('tor_method', m);
    if (_on || _busy) {
      // Changement a chaud : la nouvelle methode s'applique tout de suite.
      _plan = _buildPlan();
      _planIdx = 0;
      _driving = true;
      _lastSwitch = DateTime.now();
      await TorCtl.transport(_plan.first);
    }
  }

  Future<void> _newIdentity() async {
    await TorCtl.newIdentity();
    _setNotice(L.t('tor_newnym_done'));
    setState(() {
      _isTor = null;
      _exit = null;
    });
    await Future.delayed(const Duration(seconds: 4));
    if (mounted && _on) _check();
  }

  /// Verification independante, faite A TRAVERS Tor : torproject.org confirme
  /// que la connexion sort bien du reseau Tor, puis on lit le pays de sortie.
  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    bool? isTor;
    String? ip;
    final body = await TorCtl.fetch('https://check.torproject.org/api/ip');
    try {
      final j = jsonDecode(body!) as Map<String, dynamic>;
      isTor = j['IsTor'] == true;
      ip = j['IP'] as String?;
    } catch (_) {}
    IpInfo? info;
    if (ip != null) {
      final b2 = await TorCtl.fetch('https://ipwho.is/$ip?lang=${L.lang}');
      try {
        final j = jsonDecode(b2!) as Map<String, dynamic>;
        info = IpInfo(
          ip: ip,
          country: (j['country'] ?? '') as String,
          countryCode: (j['country_code'] ?? '') as String,
          city: (j['city'] ?? '') as String,
        );
      } catch (_) {
        info = IpInfo(ip: ip);
      }
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _isTor = isTor;
      _exit = info;
    });
  }

  Future<bool?> _showConsent() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.security),
        title: Text(L.t('consent_title')),
        content: SingleChildScrollView(child: Text(L.t('tor_consent_body'))),
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('tor_title')),
        actions: [
          IconButton(
            tooltip: L.t('risk_title'),
            icon: const Icon(Icons.warning_amber_rounded),
            onPressed: () => showRiskInfo(context),
          ),
          IconButton(
            tooltip: L.t('settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => openAppSettings(context, onChanged: () {
              if (mounted) setState(() {});
            }),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _statusCard(cs),
          if (_notice != null) _noticeCard(cs),
          if (_on) _checkCard(cs),
          _methodCard(cs),
          _protectionsCard(cs),
          _limitsCard(cs),
        ],
      ),
    );
  }

  Widget _statusCard(ColorScheme cs) {
    final Color color;
    final IconData icon;
    final String title;
    final String sub;
    if (_on) {
      color = Colors.green;
      icon = Icons.verified_user;
      title = L.t('tor_on');
      final parts = <String>[];
      if (_transport != 'direct') {
        parts.add(L.t('tor_via', {'m': _methodLabel(_transport)}));
      }
      if (_since > 0) {
        parts.add(L.t('connected_for', {
          'time': fmtDuration(DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(_since)))
        }));
      }
      sub = parts.join(' · ');
    } else if (_busy) {
      color = Colors.amber.shade700;
      icon = Icons.sync;
      title = _state == 'permission'
          ? L.t('tor_permission')
          : L.t('tor_connecting', {'p': _progress});
      sub = _methodLabel(_transport);
    } else {
      color = cs.outline;
      icon = Icons.shield_outlined;
      title = L.t('tor_off');
      sub = L.t('tor_tagline');
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 44, color: color),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (sub.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(sub,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                  value: _state == 'permission' ? null : _progress / 100),
            ],
            const SizedBox(height: 16),
            if (_on || _busy)
              OutlinedButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.power_settings_new),
                label: Text(L.t('disconnect')),
              )
            else
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.security),
                label: Text(L.t('tor_connect')),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            if (_on) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _newIdentity,
                icon: const Icon(Icons.autorenew),
                label: Text(L.t('tor_newnym')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _noticeCard(ColorScheme cs) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      color: _noticeIsError ? cs.errorContainer : cs.secondaryContainer,
      child: ListTile(
        leading: Icon(_noticeIsError ? Icons.error_outline : Icons.info_outline),
        title: Text(_notice!),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _notice = null),
        ),
      ),
    );
  }

  Widget _checkCard(ColorScheme cs) {
    Widget body;
    if (_checking) {
      body = ListTile(
        leading: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text(L.t('tor_check')),
      );
    } else if (_isTor == null) {
      body = ListTile(
        leading: const Icon(Icons.travel_explore),
        title: Text(_exit == null && _isTor == null
            ? L.t('tor_check')
            : L.t('tor_check_fail')),
        trailing: const Icon(Icons.chevron_right),
        onTap: _check,
      );
    } else {
      final ok = _isTor == true;
      final exit = _exit;
      final place = exit == null
          ? ''
          : '${flagOf(exit.countryCode)} ${exit.country.isEmpty ? exit.ip : exit.country}';
      body = ListTile(
        leading: Icon(ok ? Icons.check_circle : Icons.error,
            color: ok ? Colors.green : cs.error),
        title: Text(ok ? L.t('tor_check_ok') : L.t('tor_check_bad')),
        subtitle: exit == null
            ? null
            : Text('${L.t('tor_exit', {'country': place})}\n${exit.ip}'),
        isThreeLine: exit != null,
        trailing: IconButton(
          tooltip: L.t('tor_check'),
          icon: const Icon(Icons.refresh),
          onPressed: _check,
        ),
      );
    }
    return Card(margin: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: body);
  }

  Widget _methodCard(ColorScheme cs) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(L.t('tor_method'),
                style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final m in _methods)
            ListTile(
              leading: Icon(
                m == _method
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: m == _method ? cs.primary : null,
              ),
              title: Text(_methodLabel(m)),
              subtitle: Text(_methodDesc(m)),
              onTap: () => _selectMethod(m),
            ),
        ],
      ),
    );
  }

  Widget _protectionsCard(ColorScheme cs) {
    Widget item(IconData i, String key) => ListTile(
          dense: true,
          leading: Icon(i, color: _on ? Colors.green : cs.outline),
          title: Text(L.t(key)),
        );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(L.t('shield_title'),
                style: Theme.of(context).textTheme.titleMedium),
          ),
          item(Icons.layers_outlined, 'tor_p_relays'),
          item(Icons.dns_outlined, 'tor_p_dns'),
          item(Icons.block, 'tor_p_ipv6'),
          item(Icons.alt_route, 'tor_p_bridges'),
          item(Icons.do_not_disturb_on_outlined, 'tor_p_noads'),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _limitsCard(ColorScheme cs) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.info_outline),
              const SizedBox(width: 8),
              Expanded(child: Text(L.t('tor_limits'))),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => showRiskInfo(context),
                child: Text(L.t('risk_title')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
