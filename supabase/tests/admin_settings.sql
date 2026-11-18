-- Settings update RPC smoke test. All writes are rolled back.
begin;

do $tests$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claim.sub', 'edc8fe57-81af-4672-bb3b-ca1a6bad161a', true);
  perform set_config('request.jwt.claims',
    '{"sub":"edc8fe57-81af-4672-bb3b-ca1a6bad161a","email":"mahdi.alaei64@gmail.com","role":"authenticated"}', true);

  v_result := public.admin_update_settings('موبایل ارغوان', 2, 14, 5, 15);
  if v_result ->> 'shop_name' <> 'موبایل ارغوان' then
    raise exception 'admin_update_settings_smoke_test_failed';
  end if;

  begin
    perform public.admin_update_settings('x', 2, 14, 5, 15);
    raise exception 'invalid_settings_should_be_rejected';
  exception when others then
    if sqlerrm = 'invalid_settings_should_be_rejected' then raise; end if;
  end;
end
$tests$;

rollback;
