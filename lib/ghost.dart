// Hopora Ghost : camouflage en calculatrice, code de detresse, bouton panique.
//
// - L'icone et le nom de l'appli deviennent ceux d'une calculatrice qui
//   fonctionne vraiment. Hopora ne s'ouvre qu'avec le code secret suivi de "=".
// - Le code de detresse donne un resultat de calcul normal, mais coupe tout
//   et efface les donnees en silence.
// - Le bouton panique (appui long) coupe et efface immediatement.
// - Des que l'appli passe en arriere-plan, elle se reverrouille.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'main.dart';
import 'tor_page.dart';

const _sec = MethodChannel('hopora/secure');

/// 20 000 tours de SHA-256 (execute dans un isolate via compute()).
String _slowHash(String input) {
  List<int> h = utf8.encode(input);
  for (var i = 0; i < 20000; i++) {
    h = sha256.convert(h).bytes;
  }
  return base64Url.encode(h);
}

class Ghost {
  static bool get enabled => prefs.getBool('disguise') ?? false;

  /// true = la calculatrice est affichee a la place de Hopora.
  static final locked = ValueNotifier<bool>(false);

  /// Incremente a chaque changement de camouflage (titre de l'appli).
  static final revision = ValueNotifier<int>(0);

  static void init() => locked.value = enabled;

  static final navKey = GlobalKey<NavigatorState>();

  /// Revient a la calculatrice en fermant tout ecran ouvert par-dessus.
  static void lock() {
    navKey.currentState?.popUntil((r) => r.isFirst);
    locked.value = true;
  }

  static String _salt() {
    var salt = prefs.getString('ghost_salt');
    if (salt == null) {
      final r = math.Random.secure();
      salt = base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
      prefs.setString('ghost_salt', salt);
    }
    return salt;
  }

  /// Empreinte lente et salee, calculee hors du fil de l'interface
  /// (isolate) : aucune saccade, meme sur un vieux telephone.
  static Future<String> _hash(String code) =>
      compute(_slowHash, '${_salt()}:$code');

  static bool validCode(String c) => RegExp(r'^\d{4,8}$').hasMatch(c);

  /// 'open', 'duress' ou null.
  static Future<String?> check(String code) async {
    if (!enabled || !validCode(code)) return null;
    final h = await _hash(code);
    if (h == prefs.getString('ghost_pin')) return 'open';
    if (h == prefs.getString('ghost_duress')) return 'duress';
    return null;
  }

  static Future<void> enable(String pin, String? duress) async {
    await prefs.setString('ghost_pin', await _hash(pin));
    if (duress != null && duress.isNotEmpty) {
      await prefs.setString('ghost_duress', await _hash(duress));
    } else {
      await prefs.remove('ghost_duress');
    }
    await prefs.setBool('disguise', true);
    revision.value++;
    try {
      await _sec.invokeMethod('disguise', true);
      await _sec.invokeMethod('set', true);
    } catch (_) {}
  }

  static Future<void> disable() async {
    await prefs.setBool('disguise', false);
    await prefs.remove('ghost_pin');
    await prefs.remove('ghost_duress');
    revision.value++;
    try {
      await _sec.invokeMethod('disguise', false);
    } catch (_) {}
  }

  /// Coupe les VPN et efface toutes les traces locales. Le camouflage et ses
  /// codes sont conserves pour que l'appli reste une calculatrice.
  static Future<void> wipe() async {
    await TorCtl.stop();
    stopFastVpn?.call();
    await Future.delayed(const Duration(milliseconds: 1200));
    final keep = <String, Object?>{
      for (final k in ['disguise', 'ghost_pin', 'ghost_duress', 'ghost_salt', 'discreet'])
        k: prefs.get(k),
    };
    await prefs.clear();
    for (final e in keep.entries) {
      final v = e.value;
      if (v is bool) await prefs.setBool(e.key, v);
      if (v is String) await prefs.setString(e.key, v);
    }
    try {
      await _sec.invokeMethod('wipe');
    } catch (_) {}
  }

  /// Bouton panique : efface, puis calculatrice (ou fermeture de l'appli).
  static Future<void> panic() async {
    if (enabled) lock(); // l'ecran change immediatement
    await wipe();
    if (!enabled) await SystemNavigator.pop();
  }
}

/// Affiche Hopora ou la calculatrice, et reverrouille en arriere-plan.
class Gate extends StatefulWidget {
  const Gate({super.key});

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Court delai : la fenetre d'autorisation VPN d'Android ou une publicite
      // mettent aussi l'appli en pause.
      _lockTimer ??= Timer(const Duration(seconds: 6), () {
        if (Ghost.enabled) Ghost.lock();
      });
    } else if (state == AppLifecycleState.resumed) {
      _lockTimer?.cancel();
      _lockTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Ghost.locked,
      builder: (_, locked, __) =>
          locked ? const CalculatorScreen() : const HomeShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// Calculatrice (entierement fonctionnelle)
// ---------------------------------------------------------------------------

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  String _expr = '';
  String _result = '';

  static const _ops = '+−×÷';

  void _press(String k) {
    setState(() {
      switch (k) {
        case 'C':
          _expr = '';
          _result = '';
        case '⌫':
          if (_expr.isNotEmpty) _expr = _expr.substring(0, _expr.length - 1);
        case '=':
          _equals();
        case '±':
          _toggleSign();
        default:
          if (_result.isNotEmpty && !_ops.contains(k) && k != '%') {
            _expr = '';
          } else if (_result.isNotEmpty && _expr.isEmpty && _result != 'Error') {
            _expr = _result;
          }
          if (_result.isNotEmpty) _result = '';
          if (_ops.contains(k)) {
            if (_expr.isEmpty) return;
            if (_ops.contains(_expr[_expr.length - 1])) {
              _expr = _expr.substring(0, _expr.length - 1);
            }
          }
          if (k == '.') {
            final last = _expr.split(RegExp('[+−×÷]')).last;
            if (last.contains('.')) return;
            if (last.isEmpty) _expr += '0';
          }
          if (_expr.length < 40) _expr += k;
      }
    });
  }

  void _toggleSign() {
    final m = RegExp(r'(\(-)?[\d.]+%?$').firstMatch(_expr);
    if (m == null) return;
    final part = m.group(0)!;
    final repl = part.startsWith('(-') ? part.substring(2) : '(-$part';
    _expr = _expr.substring(0, m.start) + repl;
  }

  void _equals() {
    final raw = _expr;
    // Le resultat s'affiche immediatement ; le code secret est verifie en
    // arriere-plan (meme apparence qu'un calcul normal).
    final v = _eval(raw);
    _result = v == null ? (raw.isEmpty ? '' : 'Error') : _fmt(v);
    _expr = '';
    if (Ghost.validCode(raw)) unawaited(_checkSecret(raw));
  }

  Future<void> _checkSecret(String raw) async {
    final secret = await Ghost.check(raw);
    if (!mounted) return;
    if (secret == 'open') {
      setState(() {
        _expr = '';
        _result = '';
      });
      Ghost.locked.value = false;
    } else if (secret == 'duress') {
      unawaited(Ghost.wipe()); // en silence ; l'ecran reste une calculatrice
    }
  }

  /// Evaluation avec priorites (× ÷ avant + −), % = /100.
  double? _eval(String s) {
    if (s.isEmpty) return null;
    final tokens = <String>[];
    final re = RegExp(r'\(-[\d.]+%?|[\d.]+%?|[+−×÷]');
    for (final m in re.allMatches(s)) {
      tokens.add(m.group(0)!);
    }
    if (tokens.isEmpty || _ops.contains(tokens.last)) return null;
    double num(String t) {
      var x = t.replaceAll('(', '');
      var pct = false;
      if (x.endsWith('%')) {
        pct = true;
        x = x.substring(0, x.length - 1);
      }
      final d = double.parse(x);
      return pct ? d / 100 : d;
    }

    try {
      final terms = <double>[];
      final signs = <int>[];
      double cur = num(tokens[0]);
      for (var i = 1; i + 1 < tokens.length; i += 2) {
        final op = tokens[i];
        final n = num(tokens[i + 1]);
        if (op == '×') {
          cur *= n;
        } else if (op == '÷') {
          if (n == 0) return null;
          cur /= n;
        } else {
          terms.add(cur);
          signs.add(op == '+' ? 1 : -1);
          cur = n;
        }
      }
      var total = terms.isEmpty ? cur : terms.first;
      for (var i = 0; i < signs.length; i++) {
        final next = i + 1 < terms.length ? terms[i + 1] : cur;
        total += signs[i] * next;
      }
      if (total.isNaN || total.isInfinite) return null;
      return total;
    } catch (_) {
      return null;
    }
  }

  String _fmt(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    var s = v.toStringAsPrecision(12);
    if (s.contains('e')) return s;
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    const keys = [
      'C', '⌫', '%', '÷', //
      '7', '8', '9', '×',
      '4', '5', '6', '−',
      '1', '2', '3', '+',
      '±', '0', '.', '=',
    ];
    return Scaffold(
      backgroundColor: const Color(0xFF1C1D21),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                alignment: Alignment.bottomRight,
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _expr.isEmpty && _result.isEmpty ? '0' : _expr,
                        style: TextStyle(
                          fontSize: _result.isEmpty ? 56 : 28,
                          color: _result.isEmpty ? Colors.white : Colors.white54,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ),
                    if (_result.isNotEmpty)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _result,
                          style: const TextStyle(
                            fontSize: 60,
                            color: Colors.white,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (final k in keys)
                    _Key(
                      label: k,
                      onTap: () => _press(k),
                      color: k == '='
                          ? const Color(0xFFF58C28)
                          : _ops.contains(k)
                              ? const Color(0xFF3A3D45)
                              : (k == 'C' || k == '⌫' || k == '%' || k == '±')
                                  ? const Color(0xFF52565F)
                                  : const Color(0xFF2B2D33),
                      textColor: _ops.contains(k)
                          ? const Color(0xFFF58C28)
                          : Colors.white,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color;
  final Color textColor;
  const _Key(
      {required this.label,
      required this.onTap,
      required this.color,
      required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Center(
          child: Text(
            label,
            style: TextStyle(fontSize: 28, color: textColor),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bouton panique et reglage du camouflage
// ---------------------------------------------------------------------------

class PanicButton extends StatelessWidget {
  const PanicButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: L.t('panic_hint'),
      child: InkResponse(
        radius: 24,
        onTap: () => ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('panic_hint')))),
        onLongPress: () {
          HapticFeedback.heavyImpact();
          Ghost.panic();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.emergency_outlined,
              color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }
}

/// Active ou desactive le camouflage depuis les reglages.
Future<void> showGhostSetup(BuildContext context) async {
  if (Ghost.enabled) {
    final off = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.calculate_outlined),
        title: Text(L.t('ghost_title')),
        content: Text(L.t('ghost_desc')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('ghost_disable'))),
        ],
      ),
    );
    if (off == true) await Ghost.disable();
    return;
  }

  final pin = TextEditingController();
  final pin2 = TextEditingController();
  final duress = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        InputDecoration deco(String label) => InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              counterText: '',
            );
        Widget field(TextEditingController c, String label) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: c,
                decoration: deco(label),
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 8,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            );
        return AlertDialog(
          icon: const Icon(Icons.calculate_outlined),
          title: Text(L.t('ghost_title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L.t('ghost_setup_body')),
                field(pin, L.t('ghost_code')),
                field(pin2, L.t('ghost_code_confirm')),
                field(duress, L.t('ghost_duress')),
                const SizedBox(height: 6),
                Text(L.t('ghost_duress_help'),
                    style: Theme.of(ctx).textTheme.bodySmall),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L.t('cancel'))),
            FilledButton(
              onPressed: () {
                final a = pin.text, b = pin2.text, d = duress.text;
                final bad = !Ghost.validCode(a) ||
                    a != b ||
                    (d.isNotEmpty && (!Ghost.validCode(d) || d == a));
                if (bad) {
                  setD(() => error = L.t('ghost_bad_code'));
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(L.t('enable')),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) return;
  await Ghost.enable(pin.text, duress.text.isEmpty ? null : duress.text);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.check_circle_outline),
      title: Text(L.t('ghost_title')),
      content: Text(L.t('ghost_enabled')),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
}
