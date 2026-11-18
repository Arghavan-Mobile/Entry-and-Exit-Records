-- Restrict SECURITY DEFINER search paths for correction request and deletion RPCs.
create or replace function public.employee_submit_attendance_request(
  p_qr text,p_pin text,p_record_id uuid,p_requested_check_in timestamptz,
  p_requested_check_out timestamptz,p_reason text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_verified record;
  v_record public.attendance_records%rowtype;
  v_request_id uuid;
  v_recent_count integer;
begin
  select * into v_verified from public._verify_employee(p_qr,p_pin);
  if v_verified.err is not null then
    return jsonb_build_object('ok',false,'error',v_verified.err,'name',v_verified.emp_name,'attempts_left',v_verified.attempts_left);
  end if;
  if p_record_id is null or p_requested_check_in is null then return jsonb_build_object('ok',false,'error','invalid_request'); end if;
  if length(btrim(coalesce(p_reason,''))) < 5 then return jsonb_build_object('ok',false,'error','reason_required'); end if;
  if length(btrim(p_reason)) > 500 then return jsonb_build_object('ok',false,'error','reason_too_long'); end if;
  if p_requested_check_in > now()+interval '5 minutes'
     or (p_requested_check_out is not null and p_requested_check_out > now()+interval '5 minutes') then
    return jsonb_build_object('ok',false,'error','time_in_future');
  end if;
  if p_requested_check_out is not null and p_requested_check_out <= p_requested_check_in then
    return jsonb_build_object('ok',false,'error','invalid_time_range');
  end if;
  select * into v_record from public.attendance_records a
  where a.id=p_record_id and a.employee_id=v_verified.emp_id for update;
  if not found then return jsonb_build_object('ok',false,'error','record_not_found'); end if;
  if v_record.check_in=p_requested_check_in and v_record.check_out is not distinct from p_requested_check_out then
    return jsonb_build_object('ok',false,'error','no_changes_requested');
  end if;
  if exists(select 1 from public.attendance_correction_requests cr where cr.record_id=p_record_id and cr.status='pending') then
    return jsonb_build_object('ok',false,'error','request_already_pending');
  end if;
  select count(*) into v_recent_count from public.attendance_correction_requests cr
  where cr.employee_id=v_verified.emp_id and cr.created_at>=now()-interval '24 hours';
  if v_recent_count>=10 then return jsonb_build_object('ok',false,'error','daily_request_limit_reached'); end if;
  insert into public.attendance_correction_requests(employee_id,record_id,original_data,requested_check_in,requested_check_out,reason)
  values(v_verified.emp_id,v_record.id,
    jsonb_build_object('check_in',v_record.check_in,'check_out',v_record.check_out,'needs_review',v_record.needs_review,'edited',v_record.edited),
    p_requested_check_in,p_requested_check_out,btrim(p_reason))
  returning id into v_request_id;
  return jsonb_build_object('ok',true,'request_id',v_request_id);
end;
$$;

create or replace function public.kiosk_my_records(p_qr text,p_pin text,p_from timestamptz,p_to timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v record; recs jsonb;
begin
  select * into v from public._verify_employee(p_qr,p_pin);
  if v.err is not null then
    return jsonb_build_object('ok',false,'error',v.err,'name',v.emp_name,'attempts_left',v.attempts_left);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'check_in',a.check_in,'check_out',a.check_out,'edited',a.edited,'needs_review',a.needs_review,
    'has_pending_request',exists(select 1 from public.attendance_correction_requests cr where cr.record_id=a.id and cr.status='pending'),
    'latest_request_status',(select cr.status from public.attendance_correction_requests cr where cr.record_id=a.id order by cr.created_at desc limit 1),
    'latest_review_reason',(select cr.review_reason from public.attendance_correction_requests cr where cr.record_id=a.id order by cr.created_at desc limit 1)
  ) order by a.check_in desc),'[]'::jsonb) into recs
  from public.attendance_records a where a.employee_id=v.emp_id and a.check_in>=p_from and a.check_in<p_to;
  return jsonb_build_object('ok',true,'name',v.emp_name,'records',recs);
end;
$$;

create or replace function public.admin_delete_record(p_record uuid,p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare a text; old_r public.attendance_records%rowtype;
begin
  a:=public._require_admin();
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'reason_required'; end if;
  select * into old_r from public.attendance_records where id=p_record for update;
  if not found then raise exception 'record_not_found'; end if;
  if exists(select 1 from public.attendance_correction_requests cr where cr.record_id=p_record and cr.status='pending') then
    raise exception 'pending_correction_request_exists';
  end if;
  delete from public.attendance_records where id=p_record;
  insert into public.audit_log(admin_email,action,employee_id,record_id,old_data,reason)
  values(a,'delete_record',old_r.employee_id,old_r.id,to_jsonb(old_r),trim(p_reason));
end;
$$;
