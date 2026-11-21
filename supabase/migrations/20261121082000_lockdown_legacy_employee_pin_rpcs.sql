-- Cutover: close every browser-callable PIN-only path after device-gateway client is live.
revoke execute on function public.kiosk_attendance_code(text,text,double precision,double precision,double precision,text) from anon, authenticated;
revoke execute on function public.kiosk_my_records_pin(text,timestamptz,timestamptz) from anon, authenticated;
revoke execute on function public.kiosk_my_requests_pin(text) from anon, authenticated;
revoke execute on function public.employee_submit_leave_request_pin(text,text,date,date,text) from anon, authenticated;
revoke execute on function public.employee_submit_attendance_request_pin(text,uuid,timestamptz,timestamptz,text) from anon, authenticated;
-- Retired QR-based employee endpoints are also closed to prevent a legacy bypass.
revoke execute on function public.kiosk_scan(text,text) from anon, authenticated;
revoke execute on function public.kiosk_my_records(text,text,timestamptz,timestamptz) from anon, authenticated;
revoke execute on function public.employee_submit_attendance_request(text,text,uuid,timestamptz,timestamptz,text) from anon, authenticated;
-- Trusted Edge Function uses service_role; administrator functions remain unchanged.
