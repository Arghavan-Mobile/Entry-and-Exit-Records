create or replace function public.manager_monthly_attendance_inputs(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor text:=public._require_admin();
begin
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>370 then raise exception 'invalid_report_range' using errcode='22023'; end if;
 return jsonb_build_object(
  'employees',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'full_name',e.full_name,'active',e.active,'created_at',e.created_at) order by e.full_name),'[]'::jsonb) from public.employees e),
  'records',(select coalesce(jsonb_agg(to_jsonb(a) order by a.check_in),'[]'::jsonb) from public.attendance_records a where a.check_in >= (p_from::timestamp at time zone 'Asia/Tehran') and a.check_in < ((p_to+1)::timestamp at time zone 'Asia/Tehran')),
  'schedules',(select coalesce(jsonb_agg(to_jsonb(s) order by s.effective_from),'[]'::jsonb) from public.work_schedule_versions s where s.effective_from<=p_to),
  'holidays',(select coalesce(jsonb_agg(to_jsonb(h) order by h.holiday_date),'[]'::jsonb) from public.work_holidays h where h.holiday_date between p_from and p_to),
  'approved_leaves',(select coalesce(jsonb_agg(to_jsonb(l) order by l.start_date),'[]'::jsonb) from public.leave_requests l where l.status='approved' and l.start_date<=p_to and l.end_date>=p_from)
 );
end; $$;
revoke all on function public.manager_monthly_attendance_inputs(date,date) from public,anon;
grant execute on function public.manager_monthly_attendance_inputs(date,date) to authenticated,service_role;
