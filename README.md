# موبایل ارغوان

سامانه ثبت ورود و خروج کارکنان موبایل ارغوان.

## اجزای فعلی
- کیوسک ثبت ورود و خروج با QR و PIN
- مشاهده سوابق ماهانه کارمند با QR و PIN
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
- [آزمون‌های مجوز نقش‌ها](supabase/tests/role_access.sql)
- [آزمون توابع مدیریت سوابق](supabase/tests/admin_record_rpcs.sql)
- [آزمون تنظیمات مدیران](supabase/tests/admin_settings.sql)
- [آزمون گردش کار درخواست اصلاح](supabase/tests/attendance_correction_workflow.sql)
- [تاریخچه تغییرات](CHANGELOG.md)

## وضعیت انتشار
کد در شاخه `permission-test` قرار دارد و PR شماره ۱ برای بازبینی باز است. پایگاه داده اصلی نقش‌ها و کنترل‌های چرخه مدیر را دریافت کرده است؛ اما Edge Function دعوت مدیر هنوز به دلیل نیاز به دامنه سایت و secrets سمت سرور deploy نشده است. ادغام در `main` و انتشار عمومی فقط پس از تأیید مالک انجام می‌شود.
