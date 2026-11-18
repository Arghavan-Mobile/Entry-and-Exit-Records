# موبایل ارغوان

سامانه ثبت ورود و خروج کارکنان موبایل ارغوان.

## اجزای فعلی
- کیوسک ثبت ورود و خروج با QR و PIN
- مشاهده سوابق ماهانه و ثبت درخواست اصلاح توسط کارمند با QR و PIN
- صف بررسی درخواست‌های اصلاح در پنل مدیر
- پنل مدیریت کارکنان، کارت QR، تغییر PIN، فعال/غیرفعال‌سازی و پشتیبان‌گیری
- نقش‌های مستقل مالک و مدیر فروشگاه
- دعوت مدیر عملیاتی و پذیرش دعوت
- پنل مالک برای مشاهده مدیران فعال و لغو دسترسی/دعوت

## مستندات
- [نقشه راه توسعه](docs/ROADMAP.md)
- [گزارش امنیت و وضعیت فعلی](docs/SECURITY.md)
- [طراحی نقش‌ها و سطح دسترسی](docs/ACCESS-CONTROL.md)
- [Migration نقش‌ها](supabase/migrations/20261118184001_owner_manager_roles.sql)
- [Migration مدیریت چرخه مدیران](supabase/migrations/20261118184342_manager_lifecycle_controls.sql)
- [Migration تنظیمات ممیزی‌شده](supabase/migrations/20261118184847_admin_update_settings.sql)
- [Migration درخواست اصلاح حضور](supabase/migrations/20261118185113_attendance_correction_requests.sql)
- [Migration محافظت از رکورد دارای درخواست](supabase/migrations/20261118185131_correction_request_delete_guard.sql)
- [Migration نمایش وضعیت درخواست در سوابق](supabase/migrations/20261118185255_kiosk_correction_status.sql)
- [Migration محدودیت درخواست‌ها و مسیرهای امن](supabase/migrations/20261118185457_correction_request_rate_limits.sql)
- [Migration محدودسازی search_path توابع اصلاح](supabase/migrations/20261118185542_tighten_correction_function_search_paths.sql)
- [آزمون‌های مجوز نقش‌ها](supabase/tests/role_access.sql)
- [آزمون توابع مدیریت سوابق](supabase/tests/admin_record_rpcs.sql)
- [آزمون تنظیمات مدیران](supabase/tests/admin_settings.sql)
- [آزمون گردش کار درخواست اصلاح](supabase/tests/attendance_correction_workflow.sql)
- [تاریخچه تغییرات](CHANGELOG.md)

## میزبانی
- مقصد انتشار: GitHub Pages با آدرس پروژه `https://arghavan-mobile.github.io/Entry-and-Exit-Records/`.
- فایل‌ها به‌صورت استاتیک و بدون نیاز به build منتشر می‌شوند؛ صفحه مدیریت از مسیر `admin.html` در دسترس است.
- انتشار خودکار فقط پس از ادغام نسخه تأییدشده در شاخه `main` اجرا می‌شود.

## وضعیت انتشار
نسخه فعلی در شاخه `main` ادغام و از طریق GitHub Pages منتشر شده است. صفحه اصلی دو مسیر مستقل «ورود مالک» و «ورود مدیر» دارد و نقش حساب پس از ورود کنترل می‌شود. پس از ورود، مالک یا مدیر می‌تواند نام و نام خانوادگی و PIN هر کارمند را ثبت کند؛ سامانه کارت QR می‌سازد و امکان چاپ کارت‌ها وجود دارد. تابع Edge Function دعوت مدیر هنوز deploy نشده و راه‌اندازی دعوت ایمیلی به تنظیم secrets و redirectهای Supabase نیاز دارد.
