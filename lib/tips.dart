import 'dart:async';
import 'package:in_app_purchase/in_app_purchase.dart';

/// ONLY two tip IAPs in the whole app, ever. Both are pure donations:
/// they unlock nothing, remove nothing, and there is no paywall.
/// Product IDs follow the standing rule: no dots, no underscores,
/// and they include the app name.
/// Create these exact two products in Play Console (Monetize →
/// Products) before they can be bought; until then the Support
/// screen shows them as "not yet in the store" instead of failing.
class TipService {
  static const coffeeId = 'inkbloomcoffee';
  static const headphoneId = 'inkbloomheadphone';
  static const productIds = {coffeeId, headphoneId};

  static const coffeeTitle = 'Buy me a coffee';
  static const headphoneTitle = 'Buy me a headphone';
  static const coffeeDesc =
      'A small thank-you for InkBloom Reader. Suggested price: \$1.99.';
  static const headphoneDesc =
      'A bigger thank-you for long reading sessions. Suggested price: \$4.99.';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  List<ProductDetails> products = [];
  final List<String> thanked = [];

  Future<void> init({required void Function(String id) onThanked}) async {
    final available = await _iap.isAvailable();
    if (available) {
      final resp = await _iap.queryProductDetails(productIds);
      products = resp.productDetails;
    }
    _sub = _iap.purchaseStream.listen((purchases) async {
      for (final p in purchases) {
        if (p.status == PurchaseStatus.purchased ||
            p.status == PurchaseStatus.restored) {
          thanked.add(p.productID);
          onThanked(p.productID);
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
        }
      }
    });
  }

  Future<bool> buy(String productId) async {
    final product =
        products.where((p) => p.id == productId).firstOrNull;
    if (product == null) return false;
    return _iap.buyConsumable(
        purchaseParam: PurchaseParam(productDetails: product));
  }

  Future<void> restore() async {
    await _iap.restorePurchases();
  }

  void dispose() {
    _sub?.cancel();
  }
}
