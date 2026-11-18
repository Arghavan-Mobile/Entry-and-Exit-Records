-- End-to-end correction request workflow. All test data is rolled back.
begin;

do $tests$
declare
  v_emp1 jsonb;
  v_emp2 jsonb;
  v_emp1_id uuid;
  v_emp2_id uuid;
  v_qr1 text;
  v_rec1 jsonb;
  v_rec2 jsonb;
  v_record1 uuid;
  v_record2 uuid;
  v_req1 jsonb;
  v_req2 jsonb;
  v_req1_id uuid;
  v_req2_id uuid;
  v_count integer;
  v_record public.attendance_records%rowtype;
  v_history jsonb;
begin
  perform set_config('request.jwt.claim.sub', 'edc8fe57-81af-4672-bb3b-ca1a6bad161a', true);
  perform set_config('request.jwt.claims',
    '{"sub":"edc8fe57-81af-4672-bb3b-ca1a6bad161a","email":"mahdi.alaei64@gmail.com","role":"authenticated"}', true);

  v_emp1 := public.admin_create_employee('TEST correction owner', '1234');
  v_emp2 := public.admin_create_employee('TEST correction other', '5678');
  v_emp1_id := (v_emp1 ->> 'id')::uuid;
  v_emp2_id := (v_emp2 ->> 'id')::uuid;
  v_qr1 := v_emp1 ->> 'qr_token';

  v_rec1 := public.admin_add_record(v_emp1_id, now()-interval '4 hours', now()-interval '3 hours', 'Initial record');
  v_rec2 := public.admin_add_record(v_emp2_id, now()-interval '5 hours', now()-interval '4 hours', 'Other employee record');
  v_record1 := (v_rec1 ->> 'id')::uuid;
  v_record2 := (v_rec2 ->> 'id')::uuid;

  -- A QR/PIN identity cannot request a correction for another employee's record.
  v_req1 := public.employee_submit_attendance_request(
    v_qr1,'1234',v_record2,now()-interval '5 hours 30 minutes',now()-interval '4 hours','Cross employee attempt'
  );
  if v_req1 ->> 'error' <> 'record_not_found' then
    raise exception 'cross_employee_request_was_not_rejected';
  end if;

  v_req1 := public.employee_submit_attendance_request(
    v_qr1,'1234',v_record1,now()-interval '4 hours 30 minutes',now()-interval '3 hours','Correct my check-in time'
  );
  if v_req1 ->> 'ok' <> 'true' then raise exception 'employee_request_submission_failed: %',v_req1; end if;
  v_req1_id := (v_req1 ->> 'request_id')::uuid;

  v_history := public.kiosk_my_records(v_qr1,'1234',now()-interval '1 day',now()+interval '1 day');
  if v_history -> 'records' -> 0 ->> 'has_pending_request' <> 'true' then
    raise exception 'employee_history_pending_status_missing';
  end if;

  select count(*) into v_count from public.manager_list_attendance_requests();
  if v_count < 1 then raise exception 'manager_request_queue_empty'; end if;

  -- A pending correction blocks deletion of the referenced attendance row.
  begin
    perform public.admin_delete_record(v_record1,'Attempt delete pending correction');
    raise exception 'delete_with_pending_request_should_be_blocked';
  exception when others then
    if sqlerrm = 'delete_with_pending_request_should_be_blocked' then raise; end if;
    if sqlerrm <> 'pending_correction_request_exists' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', 'c0e814d2-971e-40c2-b8ee-bebf0fefb1d0', true);
  perform set_config('request.jwt.claims',
    '{"sub":"c0e814d2-971e-40c2-b8ee-bebf0fefb1d0","email":"ahoora7000@gmail.com","role":"authenticated"}', true);

  perform public.manager_review_attendance_request(v_req1_id,'approved','Verified against the shift log');
  select * into v_record from public.attendance_records where id=v_record1;
  if v_record.check_in <> now() - interval '4 hours 30 minutes' or v_record.edited is not true then
    raise exception 'approved_correction_not_applied';
  end if;
  v_history := public.kiosk_my_records(v_qr1,'1234',now()-interval '1 day',now()+interval '1 day');
  if v_history -> 'records' -> 0 ->> 'latest_request_status' <> 'approved' then
    raise exception 'employee_history_approval_status_missing';
  end if;

  v_req2 := public.employee_submit_attendance_request(
    v_qr1,'1234',v_record1,now()-interval '4 hours 45 minutes',now()-interval '3 hours','Second correction request'
  );
  if v_req2 ->> 'ok' <> 'true' then raise exception 'second_request_submission_failed: %',v_req2; end if;
  v_req2_id := (v_req2 ->> 'request_id')::uuid;

  perform public.manager_review_attendance_request(v_req2_id,'rejected','Evidence did not support this change');
  select count(*) into v_count from public.attendance_correction_requests
  where id=v_req2_id and status='rejected' and reviewed_at is not null;
  if v_count <> 1 then raise exception 'rejected_request_not_recorded'; end if;
end
$tests$;

rollback;
