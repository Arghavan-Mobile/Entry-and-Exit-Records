create or replace function public.kiosk_attendance_code(
  p_pin text,
  p_action text,
  p_lat double precision,
  p_lon double precision,
  p_accuracy double precision,
  p_user_agent text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  e public.employees%rowtype;
  s public.settings%rowtype;
  r public.attendance_records%rowtype;
  v_hash text;
  matches integer;
  dist double precision;
  device_data jsonb;
  v_now timestamptz := now();
  v_local_now timestamp without time zone := now() at time zone 'Asia/Tehran';
  v_effective_now timestamptz;
  v_shift1_end time;
  v_shift2_start time;
  v_workdays smallint[] := array[0,1,2,3,4,5,6]::smallint[];
  v_is_workday boolean := true;
  v_time_adjustment text := 'none';
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok',false,'error','invalid_pin'); end if;
  if coalesce(p_action,'') not in ('check_in','check_out') then return jsonb_build_object('ok',false,'error','invalid_action'); end if;
  if p_lat is null or p_lon is null or p_lat not between -90 and 90 or p_lon not between -180 and 180
    or p_accuracy is null or p_accuracy<0 or p_accuracy>50 then
    return jsonb_build_object('ok',false,'error','invalid_location','accuracy_m',p_accuracy);
  end if;

  dist:=2*6371000*asin(sqrt(
    power(sin(radians(p_lat-35.51858581595699)/2),2)+
    cos(radians(35.51858581595699))*cos(radians(p_lat))*
    power(sin(radians(p_lon-51.16386704628089)/2),2)));
  if dist>50 then return jsonb_build_object('ok',false,'error','outside_geofence',
    'distance_m',round(dist::numeric,1),'accuracy_m',round(p_accuracy::numeric,1)); end if;

  select count(*) into matches from public.employees x
  where x.active and x.pin_hash=extensions.crypt(p_pin,x.pin_hash);
  if matches=0 then return jsonb_build_object('ok',false,'error','invalid_pin'); end if;
  if matches>1 then return jsonb_build_object('ok',false,'error','duplicate_pin'); end if;

  v_hash:=encode(extensions.digest(p_pin,'sha256'),'hex');
  select * into e from public.employees x where x.active and x.employee_code_hash=v_hash for update;
  if not found then
    select * into e from public.employees x where x.active and x.pin_hash=extensions.crypt(p_pin,x.pin_hash) for update;
    update public.employees set employee_code_hash=v_hash where id=e.id;
  end if;
  if e.locked_until is not null and e.locked_until>v_now then return jsonb_build_object('ok',false,'error','locked','name',e.full_name); end if;
  update public.employees set failed_attempts=0,locked_until=null where id=e.id;

  select * into s from public.settings where id=1;
  select w.shift1_end,w.shift2_start,w.workdays
    into v_shift1_end,v_shift2_start,v_workdays
  from public.work_schedule_versions w
  where w.effective_from<=v_local_now::date
    and (w.employee_id=e.id or w.employee_id is null)
  order by (w.employee_id=e.id) desc,w.effective_from desc
  limit 1;
  if not found then
    v_shift1_end:=s.shift1_end;
    v_shift2_start:=s.shift2_start;
  end if;
  v_is_workday:=extract(dow from v_local_now)::smallint=any(coalesce(v_workdays,array[0,1,2,3,4,5,6]::smallint[]));
  if exists(select 1 from public.work_holidays h where h.holiday_date=v_local_now::date) then
    v_is_workday:=false;
  end if;

  device_data:=jsonb_build_object('user_agent',left(coalesce(p_user_agent,''),500));
  select * into r from public.attendance_records
  where employee_id=e.id and check_out is null and needs_review=false
  order by check_in desc limit 1 for update;

  if p_action='check_in' then
    if found then return jsonb_build_object('ok',false,'error','already_checked_in','name',e.full_name); end if;
    v_effective_now:=v_now;
    if v_is_workday and v_shift1_end is not null and v_shift2_start is not null
      and v_local_now::time>=v_shift1_end and v_local_now::time<v_shift2_start then
      v_effective_now:=(v_local_now::date+v_shift2_start) at time zone 'Asia/Tehran';
      v_time_adjustment:='early_second_shift_check_in_normalized_to_shift_start';
    end if;
    device_data:=device_data||jsonb_build_object(
      'actual_timestamp',v_now,
      'stored_timestamp',v_effective_now,
      'time_adjustment',v_time_adjustment
    );
    insert into public.attendance_records(employee_id,check_in,check_in_device_info)
    values(e.id,v_effective_now,device_data) returning * into r;
    return jsonb_build_object('ok',true,'action','check_in','name',e.full_name,'time',r.check_in,
      'distance_m',round(dist::numeric,1),'accuracy_m',round(p_accuracy::numeric,1));
  else
    if not found then return jsonb_build_object('ok',false,'error','no_open_shift','name',e.full_name); end if;
    if v_now-r.check_in<make_interval(mins=>s.min_gap_minutes) then return jsonb_build_object('ok',false,'error','too_soon','name',e.full_name); end if;
    if v_now-r.check_in>make_interval(hours=>s.max_shift_hours) then
      update public.attendance_records set needs_review=true where id=r.id;
      return jsonb_build_object('ok',false,'error','shift_needs_review','name',e.full_name);
    end if;
    v_effective_now:=v_now;
    if v_is_workday
      and (r.check_in at time zone 'Asia/Tehran')::date=v_local_now::date
      and (r.check_in at time zone 'Asia/Tehran')::time<v_shift2_start
      and v_shift1_end is not null and v_shift2_start is not null
      and v_local_now::time>v_shift1_end and v_local_now::time<v_shift2_start then
      v_effective_now:=(v_local_now::date+v_shift1_end) at time zone 'Asia/Tehran';
      v_time_adjustment:='late_first_shift_check_out_normalized_to_shift_end';
    end if;
    device_data:=device_data||jsonb_build_object(
      'actual_timestamp',v_now,
      'stored_timestamp',v_effective_now,
      'time_adjustment',v_time_adjustment
    );
    update public.attendance_records
      set check_out=v_effective_now,check_out_device_info=device_data
      where id=r.id returning * into r;
    return jsonb_build_object('ok',true,'action','check_out','name',e.full_name,'time',r.check_out,
      'minutes',round(extract(epoch from(r.check_out-r.check_in))/60),
      'distance_m',round(dist::numeric,1),'accuracy_m',round(p_accuracy::numeric,1));
  end if;
end
$function$;
