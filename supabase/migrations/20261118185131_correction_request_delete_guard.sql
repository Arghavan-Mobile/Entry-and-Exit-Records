create or replace function public.manager_review_attendance_request(
  p_request_id uuid,
  p_decision text,
  p_review_reason text
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
  if length(btrim(coalesce(p_review_reason, ''))) < 3 then
    raise exception 'review_reason_required';
  end if;
  select * into v_request from public.attendance_correction_requests
  where id = p_request_id for update;
  if not found then raise exception 'correction_request_not_found'; end if;
  if v_request.status <> 'pending' then raise exception 'correction_request_already_reviewed'; end if;

  if p_decision = 'approved' then
    if v_request.record_id is null then raise exception 'attendance_record_missing'; end if;
    select * into v_old from public.attendance_records
    where id = v_request.record_id and employee_id = v_request.employee_id for update;
    if not found then raise exception 'attendance_record_missing'; end if;
    update public.attendance_records
    set check_in = v_request.requested_check_in,
        check_out = v_request.requested_check_out,
        edited = true,
        needs_review = case when v_request.requested_check_out is not null then false else needs_review end
    where id = v_request.record_id returning * into v_new;
    insert into public.audit_log(admin_email,action,employee_id,record_id,old_data,new_data,reason)
    values (v_actor,'approve_attendance_correction',v_request.employee_id,v_request.record_id,
      to_jsonb(v_old),to_jsonb(v_new),
      'Employee request: ' || v_request.reason || ' | Review: ' || btrim(p_review_reason));
  else
    insert into public.audit_log(admin_email,action,employee_id,record_id,old_data,new_data,reason)
    values (v_actor,'reject_attendance_correction',v_request.employee_id,v_request.record_id,
      v_request.original_data,
      jsonb_build_object('requested_check_in',v_request.requested_check_in,'requested_check_out',v_request.requested_check_out),
      'Employee request: ' || v_request.reason || ' | Review: ' || btrim(p_review_reason));
  end if;
  update public.attendance_correction_requests
  set status=p_decision,reviewed_by=v_actor,reviewed_at=now(),review_reason=btrim(p_review_reason)
  where id=p_request_id;
  return true;
end;
$$;

create or replace function public.admin_delete_record(p_record uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  a text;
  old_r public.attendance_records%rowtype;
begin
  a := public._require_admin();
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  select * into old_r from public.attendance_records where id=p_record for update;
  if not found then raise exception 'record_not_found'; end if;
  if exists (
    select 1 from public.attendance_correction_requests cr
    where cr.record_id=p_record and cr.status='pending'
  ) then raise exception 'pending_correction_request_exists'; end if;
  delete from public.attendance_records where id=p_record;
  insert into public.audit_log(admin_email,action,employee_id,record_id,old_data,reason)
  values (a,'delete_record',old_r.employee_id,old_r.id,to_jsonb(old_r),trim(p_reason));
end;
$$;
