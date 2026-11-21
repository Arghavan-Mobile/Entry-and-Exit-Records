alter table public.settings
 add column if not exists shift1_start time not null default time '10:30',
 add column if not exists shift1_end time not null default time '14:00',
 add column if not exists shift2_start time not null default time '16:00',
 add column if not exists shift2_end time not null default time '22:00';

create or replace function public.admin_update_work_schedule(
 p_shift1_start time, p_shift1_end time, p_shift2_start time, p_shift2_end time
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_actor text:=public._require_admin(); v_old public.settings%rowtype; v_new public.settings%rowtype;
begin
 if p_shift1_start is null or p_shift1_end is null or p_shift2_start is null or p_shift2_end is null
  or p_shift1_start>=p_shift1_end or p_shift2_start>=p_shift2_end
  or p_shift1_end>=p_shift2_start then
  raise exception 'invalid_work_schedule' using errcode='22023';
 end if;
 select * into v_old from public.settings where id=1 for update;
 if not found then raise exception 'settings_not_found'; end if;
 update public.settings set shift1_start=p_shift1_start,shift1_end=p_shift1_end,
  shift2_start=p_shift2_start,shift2_end=p_shift2_end where id=1 returning * into v_new;
 insert into public.audit_log(admin_email,action,old_data,new_data,reason)
 values(v_actor,'update_work_schedule',
  jsonb_build_object('shift1_start',v_old.shift1_start,'shift1_end',v_old.shift1_end,'shift2_start',v_old.shift2_start,'shift2_end',v_old.shift2_end),
  jsonb_build_object('shift1_start',v_new.shift1_start,'shift1_end',v_new.shift1_end,'shift2_start',v_new.shift2_start,'shift2_end',v_new.shift2_end),
  'Daily split-shift schedule updated');
 return jsonb_build_object('shift1_start',v_new.shift1_start,'shift1_end',v_new.shift1_end,'shift2_start',v_new.shift2_start,'shift2_end',v_new.shift2_end);
end; $$;
revoke all on function public.admin_update_work_schedule(time,time,time,time) from public,anon;
grant execute on function public.admin_update_work_schedule(time,time,time,time) to authenticated,service_role;
