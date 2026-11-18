create or replace function public.kiosk_my_records(
  p_qr text,
  p_pin text,
  p_from timestamptz,
  p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
declare
  v record;
  recs jsonb;
begin
  select * into v from public._verify_employee(p_qr, p_pin);
  if v.err is not null then
    return jsonb_build_object('ok', false, 'error', v.err,
      'name', v.emp_name, 'attempts_left', v.attempts_left);
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'check_in', a.check_in,
        'check_out', a.check_out,
        'edited', a.edited,
        'needs_review', a.needs_review,
        'has_pending_request', exists (
          select 1 from public.attendance_correction_requests cr
          where cr.record_id = a.id and cr.status = 'pending'
        ),
        'latest_request_status', (
          select cr.status from public.attendance_correction_requests cr
          where cr.record_id = a.id order by cr.created_at desc limit 1
        ),
        'latest_review_reason', (
          select cr.review_reason from public.attendance_correction_requests cr
          where cr.record_id = a.id order by cr.created_at desc limit 1
        )
      ) order by a.check_in desc
    ), '[]'::jsonb
  ) into recs
  from public.attendance_records a
  where a.employee_id = v.emp_id and a.check_in >= p_from and a.check_in < p_to;

  return jsonb_build_object('ok', true, 'name', v.emp_name, 'records', recs);
end;
$$;
