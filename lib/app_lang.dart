/// Multilingual UI support, kept deliberately simple.
///
/// The app's books stay in whatever language they were written in —
/// this only translates the app's own buttons, headings and messages.
/// Every key falls back to English, so a missing translation can
/// never show a blank label. Urdu and Arabic switch the whole app
/// to right-to-left layout.
class AppLang {
  final String code;
  final String nativeName;
  final bool rtl;
  const AppLang(this.code, this.nativeName, this.rtl);

  static const all = [
    AppLang('en', 'English', false),
    AppLang('ur', 'اردو', true),
    AppLang('ar', 'العربية', true),
    AppLang('es', 'Español', false),
    AppLang('fr', 'Français', false),
  ];

  static AppLang fromCode(String? code) =>
      all.firstWhere((l) => l.code == code, orElse: () => all[0]);

  String t(String key) => _strings[code]?[key] ?? _strings['en']![key] ?? key;
}

const _strings = {
  'en': {
    'appTitle': 'InkBloom Reader',
    'yourBooks': 'Your books',
    'searchHint': 'Search your books…',
    'importBook': 'Import book',
    'importBooks': 'Import books',
    'noBooksYet': 'No books yet',
    'noBooksMatch': 'No books match that search',
    'importHelp':
        'Tap Import book below, pick a file from your phone, and it will appear here.\n\nWorks with: EPUB, PDF, TXT, Markdown, HTML, FB2, RTF.',
    'showAllBooks': 'Show all books',
    'tapToRead': 'Tap a book to read it.',
    'openingLibrary': 'Opening your library…',
    'openingBook': 'Opening your book…',
    'couldNotOpen': 'Could not open this book',
    'addedBooks': 'books added',
    'language': 'Language',
    'chooseLanguage': 'Choose your language',
    'all': 'All',
    'favourites': 'Favourites',
    'toRead': 'To Read',
    'reading': 'Reading',
    'finished': 'Finished',
    'settings': 'Settings',
    'dictionary': 'Dictionary',
    'support': 'Support',
    'continueReading': 'Continue reading',
  },
  'ur': {
    'appTitle': 'انک بلوم ریڈر',
    'yourBooks': 'آپ کی کتابیں',
    'searchHint': 'اپنی کتابیں تلاش کریں…',
    'importBook': 'کتاب شامل کریں',
    'importBooks': 'کتابیں شامل کریں',
    'noBooksYet': 'ابھی کوئی کتاب نہیں',
    'noBooksMatch': 'کوئی کتاب نہیں ملی',
    'importHelp':
        'نیچے کتاب شامل کریں پر ٹیپ کریں، اپنے فون سے فائل چنیں، اور وہ یہاں آ جائے گی۔\n\nیہ فارمیٹس چلتے ہیں: EPUB, PDF, TXT, Markdown, HTML, FB2, RTF.',
    'showAllBooks': 'سب کتابیں دکھائیں',
    'tapToRead': 'پڑھنے کے لیے کسی کتاب پر ٹیپ کریں۔',
    'openingLibrary': 'آپ کی لائبریری کھل رہی ہے…',
    'openingBook': 'آپ کی کتاب کھل رہی ہے…',
    'couldNotOpen': 'یہ کتاب نہیں کھل سکی',
    'addedBooks': 'کتابیں شامل ہو گئیں',
    'language': 'زبان',
    'chooseLanguage': 'اپنی زبان چنیں',
    'all': 'سب',
    'favourites': 'پسندیدہ',
    'toRead': 'پڑھنا ہے',
    'reading': 'پڑھ رہے ہیں',
    'finished': 'مکمل',
    'settings': 'ترتیبات',
    'dictionary': 'لغت',
    'support': 'مدد',
    'continueReading': 'پڑھنا جاری رکھیں',
  },
  'ar': {
    'appTitle': 'إنك بلوم ريدر',
    'yourBooks': 'كتبك',
    'searchHint': 'ابحث في كتبك…',
    'importBook': 'استيراد كتاب',
    'importBooks': 'استيراد كتب',
    'noBooksYet': 'لا توجد كتب بعد',
    'noBooksMatch': 'لا توجد كتب مطابقة',
    'importHelp':
        'اضغط على استيراد كتاب بالأسفل، واختر ملفًا من هاتفك، وسيظهر هنا.\n\nالصيغ المدعومة: EPUB, PDF, TXT, Markdown, HTML, FB2, RTF.',
    'showAllBooks': 'عرض كل الكتب',
    'tapToRead': 'اضغط على كتاب لقراءته.',
    'openingLibrary': 'جارٍ فتح مكتبتك…',
    'openingBook': 'جارٍ فتح كتابك…',
    'couldNotOpen': 'تعذّر فتح هذا الكتاب',
    'addedBooks': 'كتب مضافة',
    'language': 'اللغة',
    'chooseLanguage': 'اختر لغتك',
    'all': 'الكل',
    'favourites': 'المفضلة',
    'toRead': 'للقراءة',
    'reading': 'جارٍ القراءة',
    'finished': 'منتهية',
    'settings': 'الإعدادات',
    'dictionary': 'القاموس',
    'support': 'الدعم',
    'continueReading': 'متابعة القراءة',
  },
  'es': {
    'appTitle': 'InkBloom Reader',
    'yourBooks': 'Tus libros',
    'searchHint': 'Busca tus libros…',
    'importBook': 'Importar libro',
    'importBooks': 'Importar libros',
    'noBooksYet': 'Aún no hay libros',
    'noBooksMatch': 'Ningún libro coincide',
    'importHelp':
        'Toca Importar libro abajo, elige un archivo de tu teléfono y aparecerá aquí.\n\nFunciona con: EPUB, PDF, TXT, Markdown, HTML, FB2, RTF.',
    'showAllBooks': 'Mostrar todos los libros',
    'tapToRead': 'Toca un libro para leerlo.',
    'openingLibrary': 'Abriendo tu biblioteca…',
    'openingBook': 'Abriendo tu libro…',
    'couldNotOpen': 'No se pudo abrir este libro',
    'addedBooks': 'libros añadidos',
    'language': 'Idioma',
    'chooseLanguage': 'Elige tu idioma',
    'all': 'Todos',
    'favourites': 'Favoritos',
    'toRead': 'Por leer',
    'reading': 'Leyendo',
    'finished': 'Terminados',
    'settings': 'Ajustes',
    'dictionary': 'Diccionario',
    'support': 'Ayuda',
    'continueReading': 'Seguir leyendo',
  },
  'fr': {
    'appTitle': 'InkBloom Reader',
    'yourBooks': 'Vos livres',
    'searchHint': 'Rechercher vos livres…',
    'importBook': 'Importer un livre',
    'importBooks': 'Importer des livres',
    'noBooksYet': 'Aucun livre pour le moment',
    'noBooksMatch': 'Aucun livre correspondant',
    'importHelp':
        'Appuyez sur Importer un livre ci-dessous, choisissez un fichier sur votre téléphone, et il apparaîtra ici.\n\nFonctionne avec : EPUB, PDF, TXT, Markdown, HTML, FB2, RTF.',
    'showAllBooks': 'Afficher tous les livres',
    'tapToRead': 'Appuyez sur un livre pour le lire.',
    'openingLibrary': 'Ouverture de votre bibliothèque…',
    'openingBook': 'Ouverture de votre livre…',
    'couldNotOpen': 'Impossible d’ouvrir ce livre',
    'addedBooks': 'livres ajoutés',
    'language': 'Langue',
    'chooseLanguage': 'Choisissez votre langue',
    'all': 'Tous',
    'favourites': 'Favoris',
    'toRead': 'À lire',
    'reading': 'En cours',
    'finished': 'Terminés',
    'settings': 'Paramètres',
    'dictionary': 'Dictionnaire',
    'support': 'Aide',
    'continueReading': 'Continuer la lecture',
  },
};
