# ملاحظات وأشياء مؤجلة

## عند بناء مرحلة المؤكد (الطلبات)
- [ ] **تغيير توقيت حدث الشراء في فيسبوك وتيك توك:**
  - عند إرسال الزبون للطلبية: يُرسل **Lead** (فيسبوك) / **PlaceAnOrder** (تيك توك) بدل الشراء.
  - عندما يؤكد المؤكد الطلبية بعد الاتصال: يُرسل **Purchase** (فيسبوك) / **CompletePayment** (تيك توك) من الخادم.
  - السبب: الدفع عند الاستلام، والطلبيات الملغاة أو المرفوضة لا يجب أن تُعلّم الخوارزمية.
- [ ] لقطة شاشة إجبارية قبل التأكيد، صورة ملخص الطلبية، تقسيم الطلبية إلى طرود.

## لاحقاً
- [ ] قراءة المرجع والسعر من الصور بالذكاء الاصطناعي (يحتاج حساب console.anthropic.com وبطاقة دفع، اقترح المستخدم تجربة RedotPay).
- [ ] إشعار على هاتف صاحب المحل عند كل طلبية جديدة.
- [ ] أقسام: شركات الشحن، أدوات النظام، الإعدادات.

## Cache busting (staff.html)
On every staff.html change bump both `APPV` in staff.html and `version.txt` to the same new number; open pages then reload themselves to the new version.

## Multi-store foundation (supabase/stores.sql)
- `stores` table; current shop = store `nbdecor`. Every data table has `store_id` (default `my_store()`), RLS limits everything to the caller's store.
- A user belongs to one store: `profiles.store_id`. `my_role()` is the role inside that store.
- Shop: `index.html?s=<store>` (default `nbdecor`); `place_order(customer, items, store)`.
- Storage paths: `<store>/...`; older paths without a store folder count as `nbdecor` (`path_store()`).
- Still to do before selling: merchant sign-up + store creation, per-store order numbers (orders.id is a global sequence),
  worker phone logins are global (`<phone>@nbdecor.invalid`) so the same phone can't work in two stores,
  "store not found" page, platform-owner dashboard, subscriptions, paid Supabase plan + backups.
