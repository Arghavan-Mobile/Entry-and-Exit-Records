create or replace function public.admin_update_settings(
  p_shop_name text,
  p_min_gap_minutes integer,
  p_max_shift_hours integer,
  p_max_pin_attempts integer,
  p_lock_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor text := public._require_admin();
  v_old public.settings%rowtype;
  v_new public.settings%rowtype;
begin
  if length(btrim(coalesce(p_shop_name, ''))) < 2 or length(btrim(p_shop_name)) > 100 then
    raise exception 'invalid_shop_name';
  end if;
  if p_min_gap_minutes is null or p_min_gap_minutes < 0 or p_min_gap_minutes > 60 then
    raise exception 'invalid_min_gap_minutes';
  end if;
  if p_max_shift_hours is null or p_max_shift_hours < 1 or p_max_shift_hours > 48 then
    raise exception 'invalid_max_shift_hours';
  end if;
  if p_max_pin_attempts is null or p_max_pin_attempts < 3 or p_max_pin_attempts > 20 then
    raise exception 'invalid_max_pin_attempts';
  end if;
  if p_lock_minutes is null or p_lock_minutes < 1 or p_lock_minutes > 1440 then
    raise exception 'invalid_lock_minutes';
  end if;

  select * into v_old from public.settings where id = 1 for update;
  if not found then raise exception 'settings_not_found'; end if;

  update public.settings
  set shop_name = btrim(p_shop_name),
      min_gap_minutes = p_min_gap_minutes,
      max_shift_hours = p_max_shift_hours,
      max_pin_attempts = p_max_pin_attempts,
      lock_minutes = p_lock_minutes
  where id = 1
  returning * into v_new;

  insert into public.audit_log(admin_email, action, old_data, new_data, reason)
  values (
    v_actor,
    'update_settings',
    jsonb_build_object(
      'shop_name', v_old.shop_name,
      'min_gap_minutes', v_old.min_gap_minutes,
      'max_shift_hours', v_old.max_shift_hours,
      'max_pin_attempts', v_old.max_pin_attempts,
      'lock_minutes', v_old.lock_minutes
    ),
    jsonb_build_object(
      'shop_name', v_new.shop_name,
      'min_gap_minutes', v_new.min_gap_minutes,
      'max_shift_hours', v_new.max_shift_hours,
      'max_pin_attempts', v_new.max_pin_attempts,
      'lock_minutes', v_new.lock_minutes
    ),
    'Settings updated by an authorized administrator'
  );

  return jsonb_build_object(
    'shop_name', v_new.shop_name,
    'min_gap_minutes', v_new.min_gap_minutes,
    'max_shift_hours', v_new.max_shift_hours,
    'max_pin_attempts', v_new.max_pin_attempts,
    'lock_minutes', v_new.lock_minutes
  );
end;
$$;

revoke all on function public.admin_update_settings(text, integer, integer, integer, integer) from public, anon;
grant execute on function public.admin_update_settings(text, integer, integer, integer, integer) to authenticated;
