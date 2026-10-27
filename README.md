# FocusMode — تحسينات محلية لـ HelloTalk 6.3.51

نفس بنية مشاريع Ra (IGDownloader / RaX): كل ميزة وحدة مستقلة، كلها تتجمّع
بقائمة "Ra Menu" عائمة واحدة فيها مفتاح تشغيل/إيقاف لكل ميزة، ودايلب واحد
(`FocusMode.dylib`) يجمعها كلها.

## الوحدات
- **HTFix** — يصلح مشكلة الجلسة/الـkeychain عند السايدلود (نفس IGFix/RaXFix).
- **HTAds** — يحجب أي عرض إعلان يرث من `BaseADView` محلياً — ما يلمس الشبكة
  ولا يفعّل أي ميزة VIP.
- **HTDict** — قاموس إنجليزي مستقل تماماً عن حساب أو سيرفرات HelloTalk، زر
  📖 بأسفل Ra Menu.

## القائمة العائمة
زر Ra الدائري تقدر تسحبه لأي مكان، يفتح قائمة فيها مفتاح لكل ميزة أعلاه،
زائد زر "تقرير التشخيص" وزر "📖 القاموس".

## البناء
GitHub Actions يبني الدايلبات تلقائياً عند كل push على `main` ويحطها في
`dist/` — `dist/FocusMode.dylib` هو الدايلب النهائي اللي يحتوي كل الوحدات.

## الحقن بملف HelloTalk المفكوك
1. فك ضغط ملف الـ IPA المفكوك (6.3.51).
2. انسخ `FocusMode.dylib` إلى: `Payload/HelloTalk_Binary.app/Frameworks/`
3. أضف تحميل الدايلب للملف التنفيذي الرئيسي بأداة مثل `insert_dylib`:
   ```
   insert_dylib --inplace --all-yes \
     @executable_path/Frameworks/FocusMode.dylib \
     Payload/HelloTalk_Binary.app/HelloTalk_Binary
   ```
4. أعد ضغط المجلد لملف `.ipa`، ووقّعه وثبّته بـ Sideloadly.

## ملاحظة على التحديثات
الدايلب مبني على أسماء كلاسات استخرجتها من ملف 6.3.51 بالذات (مثل
`_TtC7HelloAd10BaseADView`). أي إصدار جديد من HelloTalk قد يغيّر هذي
الأسماء، فلازم إعادة فحص الإصدار الجديد قبل ما يُعاد البناء له.

من تطوير وإعداد راشد الشمِّري.
