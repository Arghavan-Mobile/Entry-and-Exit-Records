create table if not exists public.work_schedule_versions (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid null references public.employees(id) on delete cascade,
  effective_from date not null,
  shift1_start time not null, shift1_end time not null,
  shift2_start time not null, shift2_end time not null,
  workdays smallint[] not null default array[0,1,2,3,4,5,6]::smallint[],
  created_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  constraint work_schedule_versions_valid_times check (shift1_start < shift1_end and shift1_end < shift2_start and shift2_start < shift2_end),
  constraint work_schedule_versions_valid_workdays check (cardinality(workdays) between 1 and 7 and workdays <@ array[0,1,2,3,4,5,6]::smallint[])
);
create unique index if not exists work_schedule_versions_scope_effective_uq
  on public.work_schedule_versions (coalesce(employee_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_from);
create index if not exists work_schedule_versions_effective_idx on public.work_schedule_versions (effective_from desc);
alter table public.work_schedule_versions enable row level security;
drop policy if exists work_schedule_versions_admin_read on public.work_schedule_versions;
create policy work_schedule_versions_admin_read on public.work_schedule_versions for select to authenticated using ((select public.is_admin()));

insert into public.work_schedule_versions (employee_id,effective_from,shift1_start,shift1_end,shift2_start,shift2_end,workdays)
select null,date '1900-01-01',shift1_start,shift1_end,shift2_start,shift2_end,array[0,1,2,3,4,5,6]::smallint[]
from public.settings where id=1 on conflict do nothing;

create table if not exists public.work_holidays (
  holiday_date date primary key,
  title text not null check (length(btrim(title)) between 2 and 120),
  created_by uuid null references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.work_holidays enable row level security;
drop policy if exists work_holidays_admin_read on public.work_holidays;
create policy work_holidays_admin_read on public.work_holidays for select to authenticated using ((select public.is_admin()));

create or replace function public.admin_save_work_schedule(
  p_employee_id uuid,p_effective_from date,p_shift1_start time,p_shift1_end time,p_shift2_start time,p_shift2_end time,p_workdays smallint[]
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor text:=public._require_admin(); v_actor_id uuid:=auth.uid(); v_existing public.work_schedule_versions%rowtype; v_saved public.work_schedule_versions%rowtype;
begin
 if p_effective_from is null or p_shift1_start is null or p_shift1_end is null or p_shift2_start is null or p_shift2_end is null
  or p_shift1_start>=p_shift1_end or p_shift1_end>=p_shift2_start or p_shift2_start>=p_shift2_end then
  raise exception 'invalid_work_schedule' using errcode='22023';
 end if;
 if p_workdays is null or cardinality(p_workdays)<1 or cardinality(p_workdays)>7
  or not (p_workdays <@ array[0,1,2,3,4,5,6]::smallint[])
  or cardinality(p_workdays)<>(select count(distinct d) from unnest(p_workdays) d) then
  raise exception 'invalid_workdays' using errcode='22023';
 end if;
 if p_employee_id is not null and not exists(select 1 from public.employees e where e.id=p_employee_id) then raise exception 'employee_not_found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(p_employee_id::text,'global'),0));
 select * into v_existing from public.work_schedule_versions s where s.employee_id is not distinct from p_employee_id and s.effective_from=p_effective_from for update;
 if found then
  update public.work_schedule_versions set shift1_start=p_shift1_start,shift1_end=p_shift1_end,shift2_start=p_shift2_start,shift2_end=p_shift2_end,workdays=p_workdays,created_by=v_actor_id,created_at=now()
  where id=v_existing.id returning * into v_saved;
 else
  insert into public.work_schedule_versions(employee_id,effective_from,shift1_start,shift1_end,shift2_start,shift2_end,workdays,created_by)
  values(p_employee_id,p_effective_from,p_shift1_start,p_shift1_end,p_shift2_start,p_shift2_end,p_workdays,v_actor_id) returning * into v_saved;
 end if;
 insert into public.audit_log(admin_email,action,employee_id,old_data,new_data,reason)
 values(v_actor,'save_work_schedule_version',p_employee_id,case when v_existing.id is null then null else to_jsonb(v_existing) end,to_jsonb(v_saved),'Versioned work schedule saved; effective from '||p_effective_from::text);
 return jsonb_build_object('id',v_saved.id,'employee_id',v_saved.employee_id,'effective_from',v_saved.effective_from,
  'shift1_start',v_saved.shift1_start,'shift1_end',v_saved.shift1_end,'shift2_start',v_saved.shift2_start,'shift2_end',v_saved.shift2_end,'workdays',v_saved.workdays);
end; $$;

create or replace function public.admin_upsert_work_holiday(p_holiday_date date,p_title text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor text:=public._require_admin(); v_old public.work_holidays%rowtype; v_new public.work_holidays%rowtype;
begin
 if p_holiday_date is null or length(btrim(coalesce(p_title,'')))<2 or length(btrim(p_title))>120 then raise exception 'invalid_holiday' using errcode='22023'; end if;
 select * into v_old from public.work_holidays where holiday_date=p_holiday_date for update;
 insert into public.work_holidays(holiday_date,title,created_by) values(p_holiday_date,btrim(p_title),auth.uid())
 on conflict(holiday_date) do update set title=excluded.title,created_by=excluded.created_by returning * into v_new;
 insert into public.audit_log(admin_email,action,old_data,new_data,reason)
 values(v_actor,'upsert_work_holiday',case when v_old.holiday_date is null then null else to_jsonb(v_old) end,to_jsonb(v_new),'Holiday calendar updated');
 return to_jsonb(v_new);
end; $$;

create or replace function public.admin_delete_work_holiday(p_holiday_date date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor text:=public._require_admin(); v_old public.work_holidays%rowtype;
begin
 delete from public.work_holidays where holiday_date=p_holiday_date returning * into v_old;
 if not found then raise exception 'holiday_not_found'; end if;
 insert into public.audit_log(admin_email,action,old_data,reason) values(v_actor,'delete_work_holiday',to_jsonb(v_old),'Holiday removed from work calendar');
 return jsonb_build_object('deleted',true,'holiday_date',p_holiday_date);
end; $$;

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

revoke all on function public.admin_save_work_schedule(uuid,date,time,time,time,time,smallint[]) from public,anon;
grant execute on function public.admin_save_work_schedule(uuid,date,time,time,time,time,smallint[]) to authenticated,service_role;
revoke all on function public.admin_upsert_work_holiday(date,text) from public,anon;
grant execute on function public.admin_upsert_work_holiday(date,text) to authenticated,service_role;
revoke all on function public.admin_delete_work_holiday(date) from public,anon;
grant execute on function public.admin_delete_work_holiday(date) to authenticated,service_role;
revoke all on function public.manager_monthly_attendance_inputs(date,date) from public,anon;
grant execute on function public.manager_monthly_attendance_inputs(date,date) to authenticated,service_role;
