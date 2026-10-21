import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'custom_fonts.dart';
import 'dictionary.dart';
import 'tips.dart';

const forest = Color(0xFF173F35);
const forestDark = Color(0xFF122E28);
const terracotta = Color(0xFFE07A5F);
const cream = Color(0xFFFFF8E7);
const sage = Color(0xFFA8C3A0);

/// New InkBloom logo (2026-10-21, user request: replace the old
/// icon + splash with a professional one): an open forest book
/// blooming into a terracotta flower, generated artwork in
/// assets/inkbloom_logo.png. The same file is the Android
/// launcher icon (resized per density).
class InkBloomLogo extends StatelessWidget {
  final double size;
  const InkBloomLogo({super.key, this.size = 96});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: Image.asset('assets/inkbloom_logo.png',
            width: size, height: size, fit: BoxFit.cover),
      ),
    );
  }
}

/// Splash screen with a loading line: loads custom fonts, then
/// hands over to the library. Fast by design — it only waits for
/// real work, with a short minimum so the logo is actually seen.
class SplashScreen extends StatefulWidget {
  final WidgetBuilder home;
  const SplashScreen({super.key, required this.home});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  double _progress = 0;
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final start = DateTime.now();
    setState(() => _progress = 0.3);
    try {
      await CustomFonts.loadAll();
    } catch (_) {}
    setState(() => _progress = 0.7);
    final elapsed = DateTime.now().difference(start);
    if (elapsed < const Duration(milliseconds: 900)) {
      await Future.delayed(
          Duration(milliseconds: 900 - elapsed.inMilliseconds));
    }
    setState(() => _progress = 1);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: widget.home),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: forestDark,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const InkBloomLogo(size: 140),
            const SizedBox(height: 24),
            const Text('Ink Bloom',
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(height: 6),
            const Text('Grow your reading habit.',
                style: TextStyle(color: sage, fontSize: 16)),
            const SizedBox(height: 32),
            SizedBox(
              width: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: Colors.white24,
                  color: terracotta,
                  minHeight: 5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Loading your library…',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

/// Support screen: ONLY two IAPs, ever. Pure donations, no paywall,
/// no locked features. Prices are set in Play Console; until the
/// two products exist there, the buttons explain that honestly.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});
  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final _tips = TipService();
  bool _loading = true;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _tips.init(onThanked: (id) {
      setState(() => _message = 'Thank you! Your tip means a lot.');
    }).whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _tips.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String priceFor(String id) {
      final p =
          _tips.products.where((e) => e.id == id).firstOrNull;
      return p?.price ?? 'Price set in Play Console';
    }

    bool available(String id) =>
        _tips.products.any((e) => e.id == id);

    return Scaffold(
      appBar: AppBar(title: const Text('Support InkBloom')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Center(child: InkBloomLogo(size: 72)),
          const SizedBox(height: 16),
          const Text(
            'InkBloom Reader is completely free — every feature, '
            'every book, no paywall. These two tips are the only '
            'purchases in the app, and they unlock nothing. They '
            'are just a thank-you, if you feel like it.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (_message.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_message, textAlign: TextAlign.center),
            ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 12),
          _tipCard(
            icon: Icons.coffee,
            title: TipService.coffeeTitle,
            desc: TipService.coffeeDesc,
            price: priceFor(TipService.coffeeId),
            enabled: available(TipService.coffeeId),
            onBuy: () async {
              final ok = await _tips.buy(TipService.coffeeId);
              if (!ok && mounted) {
                setState(() => _message =
                    'This tip is not in the Play Store yet. Create product "${TipService.coffeeId}" in Play Console first.');
              }
            },
          ),
          const SizedBox(height: 12),
          _tipCard(
            icon: Icons.headphones,
            title: TipService.headphoneTitle,
            desc: TipService.headphoneDesc,
            price: priceFor(TipService.headphoneId),
            enabled: available(TipService.headphoneId),
            onBuy: () async {
              final ok = await _tips.buy(TipService.headphoneId);
              if (!ok && mounted) {
                setState(() => _message =
                    'This tip is not in the Play Store yet. Create product "${TipService.headphoneId}" in Play Console first.');
              }
            },
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              await _tips.restore();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Past tips restored, if any.')));
              }
            },
            icon: const Icon(Icons.restore),
            label: const Text('Restore past tips'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Product IDs (Play Console, no dots, no underscores):\n'
            'inkbloomcoffee • inkbloomheadphone\n'
            'Only these two. Nothing else is sold in this app.',
            style: TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _tipCard({
    required IconData icon,
    required String title,
    required String desc,
    required String price,
    required bool enabled,
    required VoidCallback onBuy,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: terracotta, size: 28),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 18))),
              Text(price,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            Text(desc),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: enabled ? onBuy : null,
              child: Text(enabled ? 'Buy this tip' : 'Not in store yet'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offline dictionary screen: search the built-in dictionary and
/// the user's own added words.
class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({super.key});
  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  String _query = '';
  Map<String, String> _custom = {};

  @override
  void initState() {
    super.initState();
    _loadCustom();
  }

  Future<void> _loadCustom() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('inkbloom_custom_dict');
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (mounted) {
        setState(() =>
            _custom = j.map((k, v) => MapEntry(k, v.toString())));
      }
    } catch (_) {}
  }

  Future<void> _saveCustom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('inkbloom_custom_dict', jsonEncode(_custom));
  }

  @override
  Widget build(BuildContext context) {
    final def = _query.isEmpty
        ? null
        : lookupWord(_query, _custom);
    return Scaffold(
      appBar: AppBar(title: const Text('Dictionary (offline)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                labelText: 'Look up a word',
                prefixIcon: Icon(Icons.book),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_query.isEmpty)
              const Text(
                  'Type any word. Definitions come from the offline dictionary built into the app — no internet needed.'),
            if (_query.isNotEmpty && def != null) ...[
              Text(_query,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 20)),
              const SizedBox(height: 8),
              Text(def, style: const TextStyle(fontSize: 16)),
            ],
            if (_query.isNotEmpty && def == null) ...[
              Text('No offline definition for "$_query" yet.',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                  'The app does not invent definitions. Add your own below and it will be saved on this phone.'),
              const SizedBox(height: 12),
              _AddDefinitionForm(
                word: _query,
                onSave: (definition) async {
                  setState(() => _custom[_query
                      .toLowerCase()
                      .replaceAll(RegExp(r"[^a-z']"), '')] = definition);
                  await _saveCustom();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddDefinitionForm extends StatefulWidget {
  final String word;
  final ValueChanged<String> onSave;
  const _AddDefinitionForm({required this.word, required this.onSave});
  @override
  State<_AddDefinitionForm> createState() => _AddDefinitionFormState();
}

class _AddDefinitionFormState extends State<_AddDefinitionForm> {
  final _controller = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'Your definition',
          border: OutlineInputBorder(),
        ),
        maxLines: 3,
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: () {
          if (_controller.text.trim().isEmpty) return;
          widget.onSave(_controller.text.trim());
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Definition saved.')));
        },
        child: const Text('Save my definition'),
      ),
    ]);
  }
}
