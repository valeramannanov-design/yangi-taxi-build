import 'dart:async';
import 'package:flutter/material.dart';

void main() => runApp(const YangiTaxiApp());

class YangiTaxiApp extends StatefulWidget {
  const YangiTaxiApp({super.key});
  @override
  State<YangiTaxiApp> createState() => _YangiTaxiAppState();
}

class _YangiTaxiAppState extends State<YangiTaxiApp> {
  String lang = 'ru';
  bool loggedIn = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Yangi Taxi',
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF16A34A)), useMaterial3: true),
    home: loggedIn
      ? Home(lang: lang, onLang: (v) => setState(() => lang = v), onLogout: () => setState(() => loggedIn = false))
      : Login(lang: lang, onLang: (v) => setState(() => lang = v), onLogin: () => setState(() => loggedIn = true)),
  );
}

String tr(String lang, String ru, String uz) => lang == 'uz' ? uz : ru;

class Login extends StatelessWidget {
  const Login({super.key, required this.lang, required this.onLang, required this.onLogin});
  final String lang;
  final ValueChanged<String> onLang;
  final VoidCallback onLogin;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 430),
      child: Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(width: 54, height: 54, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.local_taxi, color: Colors.white, size: 30)),
          const SizedBox(width: 14),
          const Expanded(child: Text('Yangi Taxi', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          SegmentedButton<String>(segments: const [ButtonSegment(value: 'ru', label: Text('RU')), ButtonSegment(value: 'uz', label: Text('UZ'))], selected: {lang}, onSelectionChanged: (v) => onLang(v.first)),
        ]),
        const SizedBox(height: 28),
        TextField(controller: TextEditingController(text: '+998 90 123 45 67'), decoration: InputDecoration(labelText: tr(lang, 'Телефон', 'Telefon'), prefixIcon: const Icon(Icons.phone), border: const OutlineInputBorder())),
        const SizedBox(height: 14),
        TextField(controller: TextEditingController(text: '123456'), obscureText: true, decoration: InputDecoration(labelText: tr(lang, 'Пароль', 'Parol'), prefixIcon: const Icon(Icons.lock_outline), border: const OutlineInputBorder())),
        const SizedBox(height: 18),
        FilledButton.icon(onPressed: onLogin, icon: const Icon(Icons.login), label: Text(tr(lang, 'Войти', 'Kirish'))),
        const SizedBox(height: 12),
        Text(tr(lang, 'Демо-версия. Сервер не требуется.', 'Demo versiya. Server kerak emas.'), textAlign: TextAlign.center),
      ]))))))),
  );
}

class Ride {
  Ride(this.from, this.to, this.price, this.tariff, {this.cancelled = false});
  final String from, to, tariff;
  final int price;
  final bool cancelled;
  Ride cancel() => Ride(from, to, price, tariff, cancelled: true);
}

class Home extends StatefulWidget {
  const Home({super.key, required this.lang, required this.onLang, required this.onLogout});
  final String lang;
  final ValueChanged<String> onLang;
  final VoidCallback onLogout;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  Ride? ride;
  final history = <Ride>[];
  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: tab, children: [
      OrderPage(lang: widget.lang, active: ride != null, onOrder: (r) => setState(() { ride = r; tab = 1; })),
      RidePage(lang: widget.lang, ride: ride, onDone: (r) => setState(() { history.insert(0, r); ride = null; })),
      HistoryPage(lang: widget.lang, items: history),
      ProfilePage(lang: widget.lang, onLang: widget.onLang, onLogout: widget.onLogout),
    ]),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v), destinations: [
      NavigationDestination(icon: const Icon(Icons.route), label: tr(widget.lang, 'Заказ', 'Buyurtma')),
      NavigationDestination(icon: const Icon(Icons.local_taxi), label: tr(widget.lang, 'Поездка', 'Safar')),
      NavigationDestination(icon: const Icon(Icons.history), label: tr(widget.lang, 'История', 'Tarix')),
      NavigationDestination(icon: const Icon(Icons.person), label: tr(widget.lang, 'Профиль', 'Profil')),
    ]),
  );
}

class OrderPage extends StatefulWidget {
  const OrderPage({super.key, required this.lang, required this.active, required this.onOrder});
  final String lang;
  final bool active;
  final ValueChanged<Ride> onOrder;
  @override
  State<OrderPage> createState() => _OrderPageState();
}

class _OrderPageState extends State<OrderPage> {
  final from = TextEditingController(text: 'Amir Temur xiyoboni');
  final to = TextEditingController(text: 'Toshkent xalqaro aeroporti');
  int tariff = 0;
  @override
  Widget build(BuildContext context) {
    final names = [tr(widget.lang, 'Эконом', 'Ekonom'), tr(widget.lang, 'Комфорт', 'Komfort'), tr(widget.lang, 'Бизнес', 'Biznes')];
    const prices = [28000, 36000, 52000];
    return Scaffold(appBar: AppBar(title: const Text('Yangi Taxi', style: TextStyle(fontWeight: FontWeight.w800))), body: ListView(padding: const EdgeInsets.all(16), children: [
      Container(height: 200, decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), gradient: const LinearGradient(colors: [Color(0xFFDCFCE7), Color(0xFFDBEAFE)])), child: const Stack(children: [Positioned(left: 24, top: 30, child: Icon(Icons.location_on, size: 44)), Positioned(right: 30, bottom: 30, child: Icon(Icons.local_taxi, size: 58)), Center(child: Text('Tashkent', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)))])),
      const SizedBox(height: 16),
      TextField(controller: from, decoration: InputDecoration(labelText: tr(widget.lang, 'Откуда', 'Qayerdan'), prefixIcon: const Icon(Icons.radio_button_checked), border: const OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: to, decoration: InputDecoration(labelText: tr(widget.lang, 'Куда', 'Qayerga'), prefixIcon: const Icon(Icons.location_on), border: const OutlineInputBorder())),
      const SizedBox(height: 16),
      ...List.generate(3, (i) => Card(child: RadioListTile<int>(value: i, groupValue: tariff, onChanged: (v) => setState(() => tariff = v ?? 0), title: Text(names[i], style: const TextStyle(fontWeight: FontWeight.w700)), secondary: Text('${prices[i]} UZS')))),
      const SizedBox(height: 10),
      FilledButton.icon(onPressed: widget.active ? null : () => widget.onOrder(Ride(from.text, to.text, prices[tariff], names[tariff])), icon: const Icon(Icons.local_taxi), label: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(widget.active ? tr(widget.lang, 'Уже есть заказ', 'Faol buyurtma bor') : '${tr(widget.lang, 'Заказать', 'Buyurtma')} • ${prices[tariff]} UZS'))),
    ]));
  }
}

class RidePage extends StatefulWidget {
  const RidePage({super.key, required this.lang, required this.ride, required this.onDone});
  final String lang;
  final Ride? ride;
  final ValueChanged<Ride> onDone;
  @override
  State<RidePage> createState() => _RidePageState();
}

class _RidePageState extends State<RidePage> {
  int step = 0;
  Timer? timer;
  @override
  void didUpdateWidget(covariant RidePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ride != null && oldWidget.ride != widget.ride) {
      step = 0; timer?.cancel(); timer = Timer.periodic(const Duration(seconds: 4), (_) { if (mounted && step < 3) setState(() => step++); });
    }
  }
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  String status() => [tr(widget.lang, 'Ищем машину', 'Mashina qidirilmoqda'), tr(widget.lang, 'Водитель назначен', 'Haydovchi tayinlandi'), tr(widget.lang, 'Машина подана', 'Mashina yetib keldi'), tr(widget.lang, 'Вы в пути', 'Yo‘ldasiz')][step];
  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    if (r == null) return Scaffold(appBar: AppBar(title: Text(tr(widget.lang, 'Текущий заказ', 'Joriy buyurtma'))), body: Center(child: Text(tr(widget.lang, 'Нет активного заказа', 'Faol buyurtma yo‘q'))));
    return Scaffold(appBar: AppBar(title: Text(status(), style: const TextStyle(fontWeight: FontWeight.w800))), body: ListView(padding: const EdgeInsets.all(16), children: [
      Container(height: 240, decoration: BoxDecoration(color: const Color(0xFFEAF4EE), borderRadius: BorderRadius.circular(20)), child: Stack(children: [const Positioned(left: 26, top: 34, child: Icon(Icons.radio_button_checked, size: 32)), const Positioned(right: 30, bottom: 30, child: Icon(Icons.location_on, size: 42)), Positioned(left: 55.0 + step * 55, top: 105.0 + step * 15, child: Container(padding: const EdgeInsets.all(10), decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF16A34A)), child: const Icon(Icons.local_taxi, color: Colors.white)))])),
      const SizedBox(height: 12),
      const Card(child: ListTile(leading: CircleAvatar(child: Icon(Icons.person)), title: Text('Azizbek Karimov'), subtitle: Text('Chevrolet Cobalt • 01 Y 001 TX'), trailing: Icon(Icons.phone))),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(status(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(height: 12), Text('● ${r.from}'), const SizedBox(height: 8), Text('● ${r.to}'), const Divider(height: 24), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(r.tariff), Text('${r.price} UZS', style: const TextStyle(fontWeight: FontWeight.w800))])]))),
      const SizedBox(height: 10),
      if (step < 3) OutlinedButton.icon(onPressed: () { timer?.cancel(); widget.onDone(r.cancel()); }, icon: const Icon(Icons.close), label: Text(tr(widget.lang, 'Отменить заказ', 'Buyurtmani bekor qilish'))) else FilledButton.icon(onPressed: () { timer?.cancel(); widget.onDone(r); }, icon: const Icon(Icons.check), label: Text(tr(widget.lang, 'Завершить демо-поездку', 'Demo safarni tugatish'))),
    ]));
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.lang, required this.items});
  final String lang;
  final List<Ride> items;
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(tr(lang, 'История', 'Tarix'))), body: items.isEmpty ? Center(child: Text(tr(lang, 'История пока пуста', 'Tarix hozircha bo‘sh'))) : ListView.builder(padding: const EdgeInsets.all(12), itemCount: items.length, itemBuilder: (_, i) { final r = items[i]; return Card(child: ListTile(leading: CircleAvatar(child: Icon(r.cancelled ? Icons.close : Icons.check)), title: Text('${r.from} → ${r.to}', maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text(r.cancelled ? tr(lang, 'Отменён', 'Bekor qilingan') : tr(lang, 'Завершён', 'Tugallangan')), trailing: Text('${r.price}'))); }));
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.lang, required this.onLang, required this.onLogout});
  final String lang;
  final ValueChanged<String> onLang;
  final VoidCallback onLogout;
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(tr(lang, 'Профиль', 'Profil'))), body: ListView(padding: const EdgeInsets.all(16), children: [
    const Card(child: ListTile(leading: CircleAvatar(radius: 28, child: Icon(Icons.person)), title: Text('Yangi Taxi Demo', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('+998 90 123 45 67'))),
    Card(child: ListTile(title: Text(tr(lang, 'Язык приложения', 'Ilova tili')), trailing: SegmentedButton<String>(segments: const [ButtonSegment(value: 'ru', label: Text('RU')), ButtonSegment(value: 'uz', label: Text('UZ'))], selected: {lang}, onSelectionChanged: (v) => onLang(v.first)))),
    const Card(child: ListTile(leading: Icon(Icons.savings_outlined), title: Text('Бонусы / Bonuslar'), trailing: Text('12 000'))),
    const SizedBox(height: 18),
    OutlinedButton.icon(onPressed: onLogout, icon: const Icon(Icons.logout), label: Text(tr(lang, 'Выйти', 'Chiqish'))),
  ]));
}
