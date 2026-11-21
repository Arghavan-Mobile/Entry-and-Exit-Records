-- Manager-controlled employee device enrollment lifecycle.
create or replace function public.manager_authorize_employee_device(p_employee uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_email text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if not public.is_admin() then raise exception 'not_authorized' using errcode='42501'; end if;
  update public.employee_devices set status='revoked', revoked_at=now()
   where employee_id=p_employee and status in ('active','pending');
  update public.employees set device_enrollment_authorized=true,
    device_enrollment_authorized_by=v_actor, device_enrollment_authorized_at=now()
   where id=p_employee and active;
  if not found then raise exception 'employee_not_found'; end if;
  insert into public.audit_log(admin_email,action,employee_id,reason,new_data)
   values(v_email,'authorize_employee_device_replacement',p_employee,
          'Manager authorized replacement device',
          jsonb_build_object('authorized',true));
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.manager_list_employee_devices()
returns table(device_id uuid, employee_id uuid, employee_name text, device_label text,
              status text, created_at timestamptz, approved_at timestamptz, last_seen_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare v_actor text := public._require_admin();
begin
 return query
 select d.id,d.employee_id,e.full_name,d.device_label,d.status,d.created_at,d.approved_at,d.last_seen_at
 from public.employee_devices d join public.employees e on e.id=d.employee_id
 where d.status in ('pending','active')
 order by case d.status when 'pending' then 0 else 1 end,d.created_at desc;
end;
$$;

create or replace function public.manager_review_employee_device(p_device uuid,p_decision text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_email text := lower(coalesce(auth.jwt()->>'email',''));
 v_device public.employee_devices%rowtype;
begin
 if not public.is_admin() then raise exception 'not_authorized' using errcode='42501'; end if;
 if p_decision not in ('approved','rejected') then raise exception 'invalid_decision'; end if;
 select * into v_device from public.employee_devices where id=p_device for update;
 if not found or v_device.status <> 'pending' then raise exception 'device_request_not_pending'; end if;
 if p_decision='approved' then
   if exists(select 1 from public.employee_devices where employee_id=v_device.employee_id and status='active') then
     raise exception 'employee_already_has_active_device';
   end if;
   update public.employee_devices set status='active',approved_by=v_actor,approved_at=now()
    where id=p_device;
   update public.employees set device_enrollment_authorized=false,
     device_enrollment_authorized_by=null,device_enrollment_authorized_at=null
    where id=v_device.employee_id;
 else
   update public.employee_devices set status='rejected' where id=p_device;
   update public.employees set device_enrollment_authorized=false,
     device_enrollment_authorized_by=null,device_enrollment_authorized_at=null
    where id=v_device.employee_id;
 end if;
 insert into public.audit_log(admin_email,action,employee_id,reason,new_data)
 values(v_email,'review_employee_device_'||p_decision,v_device.employee_id,
        'Device enrollment review',jsonb_build_object('device_id',p_device,'decision',p_decision));
 return true;
end;
$$;

revoke all on function public.manager_authorize_employee_device(uuid) from public, anon;
revoke all on function public.manager_list_employee_devices() from public, anon;
revoke all on function public.manager_review_employee_device(uuid,text) from public, anon;
grant execute on function public.manager_authorize_employee_device(uuid) to authenticated, service_role;
grant execute on function public.manager_list_employee_devices() to authenticated, service_role;
grant execute on function public.manager_review_employee_device(uuid,text) to authenticated, service_role;

-- PIN verification used only by the trusted device gateway; it never exposes the PIN hash.
create or replace function public.device_gateway_verify_pin(p_pin text)
returns table(employee_id uuid, employee_name text, enrollment_authorized boolean)
language plpgsql security definer set search_path = ''
as $$
declare e public.employees%rowtype; n integer; s public.settings%rowtype;
begin
 if coalesce(p_pin,'') !~ '^[0-9]{4,6}$' then return; end if;
 select * into s from public.settings where id=1;
 select count(*) into n from public.employees x
  where x.active and x.pin_hash=extensions.crypt(p_pin,x.pin_hash);
 if n<>1 then return; end if;
 select * into e from public.employees x
  where x.active and x.pin_hash=extensions.crypt(p_pin,x.pin_hash) for update;
 if e.locked_until is not null and e.locked_until>now() then return; end if;
 update public.employees set failed_attempts=0,locked_until=null where id=e.id;
 return query select e.id,e.full_name,e.device_enrollment_authorized;
end;
$$;
revoke all on function public.device_gateway_verify_pin(text) from public, anon, authenticated;
grant execute on function public.device_gateway_verify_pin(text) to service_role;
