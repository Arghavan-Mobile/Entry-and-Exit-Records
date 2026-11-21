-- Employee leave requests with PIN-only kiosk access and manager review.
create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete restrict,
  leave_type text not null check (leave_type in ('annual','sick','unpaid','other')),
  start_date date not null,
  end_date date not null,
  reason text not null check (length(btrim(reason)) >= 5 and length(btrim(reason)) <= 500),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_by text,
  reviewed_at timestamptz,
  review_reason text check (review_reason is null or length(btrim(review_reason)) <= 500),
  constraint leave_dates_valid check (end_date >= start_date)
);

create index leave_requests_employee_idx
  on public.leave_requests(employee_id, created_at desc);
create index leave_requests_status_idx
  on public.leave_requests(status, created_at asc);

alter table public.leave_requests enable row level security;
revoke all on public.leave_requests from public, anon, authenticated;

create or replace function public.employee_submit_leave_request_pin(
  p_pin text,
  p_leave_type text,
  p_start_date date,
  p_end_date date,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  e public.employees%rowtype;
  n integer;
  v_hash text;
  recent integer;
  req uuid;
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  select count(*) into n
  from public.employees x
  where x.active and x.pin_hash = extensions.crypt(p_pin, x.pin_hash);

  if n = 0 then return jsonb_build_object('ok', false, 'error', 'invalid_pin'); end if;
  if n > 1 then return jsonb_build_object('ok', false, 'error', 'duplicate_pin'); end if;

  v_hash := encode(extensions.digest(p_pin, 'sha256'), 'hex');
  select * into e
  from public.employees x
  where x.active and x.employee_code_hash = v_hash
  for update;

  if not found then
    select * into e
    from public.employees x
    where x.active and x.pin_hash = extensions.crypt(p_pin, x.pin_hash)
    for update;
    update public.employees set employee_code_hash = v_hash where id = e.id;
  end if;

  if e.locked_until is not null and e.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;

  if p_leave_type not in ('annual','sick','unpaid','other')
     or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    return jsonb_build_object('ok', false, 'error', 'invalid_leave_dates');
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;
  if length(btrim(p_reason)) > 500 then
    return jsonb_build_object('ok', false, 'error', 'reason_too_long');
  end if;

  if exists (
    select 1 from public.leave_requests lr
    where lr.employee_id = e.id
      and lr.status in ('pending','approved')
      and daterange(lr.start_date, lr.end_date, '[]') &&
          daterange(p_start_date, p_end_date, '[]')
  ) then
    return jsonb_build_object('ok', false, 'error', 'leave_overlap');
  end if;

  select count(*) into recent
  from public.leave_requests lr
  where lr.employee_id = e.id
    and lr.created_at >= now() - interval '24 hours';
  if recent >= 10 then
    return jsonb_build_object('ok', false, 'error', 'daily_request_limit_reached');
  end if;

  insert into public.leave_requests(employee_id, leave_type, start_date, end_date, reason)
  values (e.id, p_leave_type, p_start_date, p_end_date, btrim(p_reason))
  returning id into req;

  return jsonb_build_object('ok', true, 'request_id', req);
end;
$function$;

create or replace function public.kiosk_my_requests_pin(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  e public.employees%rowtype;
  n integer;
  v_hash text;
  reqs jsonb;
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  select count(*) into n
  from public.employees x
  where x.active and x.pin_hash = extensions.crypt(p_pin, x.pin_hash);
  if n = 0 then return jsonb_build_object('ok', false, 'error', 'invalid_pin'); end if;
  if n > 1 then return jsonb_build_object('ok', false, 'error', 'duplicate_pin'); end if;

  v_hash := encode(extensions.digest(p_pin, 'sha256'), 'hex');
  select * into e
  from public.employees x
  where x.active and x.employee_code_hash = v_hash
  for update;

  if not found then
    select * into e
    from public.employees x
    where x.active and x.pin_hash = extensions.crypt(p_pin, x.pin_hash)
    for update;
    update public.employees set employee_code_hash = v_hash where id = e.id;
  end if;

  if e.locked_until is not null and e.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;

  select coalesce(jsonb_agg(q.item order by q.created_at desc), '[]'::jsonb)
  into reqs
  from (
    select cr.created_at,
      jsonb_build_object(
        'id', cr.id,
        'request_type', 'attendance_correction',
        'request_label', 'درخواست ویرایش حضور و غیاب',
        'request_reason', cr.reason,
        'status', cr.status,
        'review_reason', cr.review_reason,
        'created_at', cr.created_at,
        'requested_check_in', cr.requested_check_in,
        'requested_check_out', cr.requested_check_out
      ) as item
    from public.attendance_correction_requests cr
    where cr.employee_id = e.id
    union all
    select lr.created_at,
      jsonb_build_object(
        'id', lr.id,
        'request_type', 'leave',
        'request_label', 'درخواست مرخصی',
        'leave_type', lr.leave_type,
        'start_date', lr.start_date,
        'end_date', lr.end_date,
        'request_reason', lr.reason,
        'status', lr.status,
        'review_reason', lr.review_reason,
        'created_at', lr.created_at
      ) as item
    from public.leave_requests lr
    where lr.employee_id = e.id
  ) q
  limit 50;

  return jsonb_build_object('ok', true, 'name', e.full_name, 'requests', reqs);
end;
$function$;

create or replace function public.manager_list_leave_requests()
returns table(
  request_id uuid,
  employee_id uuid,
  employee_name text,
  leave_type text,
  start_date date,
  end_date date,
  request_reason text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor text := public._require_admin();
begin
  return query
  select lr.id, lr.employee_id, e.full_name, lr.leave_type,
         lr.start_date, lr.end_date, lr.reason, lr.created_at
  from public.leave_requests lr
  join public.employees e on e.id = lr.employee_id
  where lr.status = 'pending'
  order by lr.created_at asc
  limit 200;
end;
$function$;

create or replace function public.manager_review_leave_request(
  p_request_id uuid,
  p_decision text,
  p_review_reason text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor text := public._require_admin();
  v_request public.leave_requests%rowtype;
begin
  if p_decision is null or p_decision not in ('approved','rejected') then
    raise exception 'invalid_review_decision';
  end if;
  if length(btrim(coalesce(p_review_reason, ''))) < 3 then
    raise exception 'review_reason_required';
  end if;
  if length(btrim(p_review_reason)) > 500 then
    raise exception 'review_reason_too_long';
  end if;

  select * into v_request
  from public.leave_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'leave_request_not_found'; end if;
  if v_request.status <> 'pending' then raise exception 'leave_request_already_reviewed'; end if;

  if p_decision = 'approved' and exists (
    select 1 from public.leave_requests lr
    where lr.employee_id = v_request.employee_id
      and lr.id <> v_request.id
      and lr.status = 'approved'
      and daterange(lr.start_date, lr.end_date, '[]') &&
          daterange(v_request.start_date, v_request.end_date, '[]')
  ) then
    raise exception 'leave_overlap_approved';
  end if;

  update public.leave_requests
  set status = p_decision,
      reviewed_by = v_actor,
      reviewed_at = now(),
      review_reason = btrim(p_review_reason)
  where id = p_request_id;

  insert into public.audit_log(admin_email, action, employee_id, old_data, new_data, reason)
  values (
    v_actor,
    case when p_decision = 'approved' then 'approve_leave_request' else 'reject_leave_request' end,
    v_request.employee_id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object(
      'status', p_decision,
      'leave_type', v_request.leave_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date
    ),
    'Employee request: ' || v_request.reason || ' | Review: ' || btrim(p_review_reason)
  );

  return true;
end;
$function$;

revoke all on function public.employee_submit_leave_request_pin(text,text,date,date,text) from public;
revoke all on function public.kiosk_my_requests_pin(text) from public;
revoke all on function public.manager_list_leave_requests() from public, anon;
revoke all on function public.manager_review_leave_request(uuid,text,text) from public, anon;

grant execute on function public.employee_submit_leave_request_pin(text,text,date,date,text) to anon, authenticated;
grant execute on function public.kiosk_my_requests_pin(text) to anon, authenticated;
grant execute on function public.manager_list_leave_requests() to authenticated;
grant execute on function public.manager_review_leave_request(uuid,text,text) to authenticated;

comment on table public.leave_requests is
  'Employee leave requests submitted with employee PIN and reviewed by an authorized store manager or owner.';
