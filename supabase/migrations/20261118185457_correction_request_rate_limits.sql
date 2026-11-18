alter table public.attendance_correction_requests
  add constraint correction_reason_max_length check (length(reason) <= 500);
alter table public.attendance_correction_requests
  add constraint correction_review_reason_max_length
  check (review_reason is null or length(review_reason) <= 500);

create or replace function public.employee_submit_attendance_request(
  p_qr text,
  p_pin text,
  p_record_id uuid,
  p_requested_check_in timestamptz,
  p_requested_check_out timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
declare
  v_verified record;
  v_record public.attendance_records%rowtype;
  v_request_id uuid;
  v_recent_count integer;
begin
  select * into v_verified from public._verify_employee(p_qr, p_pin);
  if v_verified.err is not null then
    return jsonb_build_object('ok', false, 'error', v_verified.err,
      'name', v_verified.emp_name, 'attempts_left', v_verified.attempts_left);
  end if;
  if p_record_id is null or p_requested_check_in is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;
  if length(btrim(p_reason)) > 500 then
    return jsonb_build_object('ok', false, 'error', 'reason_too_long');
  end if;
  if p_requested_check_in > now() + interval '5 minutes'
     or (p_requested_check_out is not null and p_requested_check_out > now() + interval '5 minutes') then
    return jsonb_build_object('ok', false, 'error', 'time_in_future');
  end if;
  if p_requested_check_out is not null and p_requested_check_out <= p_requested_check_in then
    return jsonb_build_object('ok', false, 'error', 'invalid_time_range');
  end if;

  select * into v_record from public.attendance_records a
  where a.id = p_record_id and a.employee_id = v_verified.emp_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'record_not_found'); end if;
  if v_record.check_in = p_requested_check_in
     and v_record.check_out is not distinct from p_requested_check_out then
    return jsonb_build_object('ok', false, 'error', 'no_changes_requested');
  end if;
  if exists (
    select 1 from public.attendance_correction_requests cr
    where cr.record_id = p_record_id and cr.status = 'pending'
  ) then
    return jsonb_build_object('ok', false, 'error', 'request_already_pending');
  end if;

  select count(*) into v_recent_count
  from public.attendance_correction_requests cr
  where cr.employee_id = v_verified.emp_id
    and cr.created_at >= now() - interval '24 hours';
  if v_recent_count >= 10 then
    return jsonb_build_object('ok', false, 'error', 'daily_request_limit_reached');
  end if;

  insert into public.attendance_correction_requests(
    employee_id, record_id, original_data, requested_check_in, requested_check_out, reason
  )
  values (
    v_verified.emp_id, v_record.id,
    jsonb_build_object('check_in',v_record.check_in,'check_out',v_record.check_out,
      'needs_review',v_record.needs_review,'edited',v_record.edited),
    p_requested_check_in,p_requested_check_out,btrim(p_reason)
  )
  returning id into v_request_id;
  return jsonb_build_object('ok',true,'request_id',v_request_id);
end;
$$;

create or replace function public.manager_review_attendance_request(
  p_request_id uuid,p_decision text,p_review_reason text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor text := public._require_admin();
  v_request public.attendance_correction_requests%rowtype;
  v_old public.attendance_records%rowtype;
  v_new public.attendance_records%rowtype;
begin
  if p_decision is null or p_decision not in ('approved','rejected') then
    raise exception 'invalid_review_decision';
  end if;
  if length(btrim(coalesce(p_review_reason,''))) < 3 then
    raise exception 'review_reason_required';
  end if;
  if length(btrim(p_review_reason)) > 500 then
    raise exception 'review_reason_too_long';
  end if;
  select * into v_request from public.attendance_correction_requests
  where id=p_request_id for update;
  if not found then raise exception 'correction_request_not_found'; end if;
  if v_request.status <> 'pending' then raise exception 'correction_request_already_reviewed'; end if;

  if p_decision='approved' then
    if v_request.record_id is null then raise exception 'attendance_record_missing'; end if;
    select * into v_old from public.attendance_records
    where id=v_request.record_id and employee_id=v_request.employee_id for update;
    if not found then raise exception 'attendance_record_missing'; end if;
    update public.attendance_records
    set check_in=v_request.requested_check_in,check_out=v_request.requested_check_out,
        edited=true,
        needs_review=case when v_request.requested_check_out is not null then false else needs_review end
    where id=v_request.record_id returning * into v_new;
    insert into public.audit_log(admin_email,action,employee_id,record_id,old_data,new_data,reason)
    values(v_actor,'approve_attendance_correction',v_request.employee_id,v_request.record_id,
      to_jsonb(v_old),to_jsonb(v_new),
      'Employee request: '||v_request.reason||' | Review: '||btrim(p_review_reason));
  else
    insert into public.audit_log(admin_email,action,employee_id,record_id,old_data,new_data,reason)
    values(v_actor,'reject_attendance_correction',v_request.employee_id,v_request.record_id,
      v_request.original_data,
      jsonb_build_object('requested_check_in',v_request.requested_check_in,'requested_check_out',v_request.requested_check_out),
      'Employee request: '||v_request.reason||' | Review: '||btrim(p_review_reason));
  end if;
  update public.attendance_correction_requests
  set status=p_decision,reviewed_by=v_actor,reviewed_at=now(),review_reason=btrim(p_review_reason)
  where id=p_request_id;
  return true;
end;
$$;
