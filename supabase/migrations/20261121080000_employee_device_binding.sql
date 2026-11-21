-- Device-bound employee authentication for Arghavan Mobile.
-- Additive migration: legacy RPCs remain callable until the Edge gateway is deployed and smoke-tested.
alter table public.employees
  add column if not exists device_enrollment_authorized boolean not null default false,
  add column if not exists device_enrollment_authorized_by uuid references auth.users(id),
  add column if not exists device_enrollment_authorized_at timestamptz;

create table if not exists public.employee_devices (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  public_jwk jsonb not null,
  device_label text not null default 'مرورگر پرسنل',
  status text not null default 'pending' check (status in ('pending','active','rejected','revoked')),
  created_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  constraint employee_devices_public_jwk_object check (jsonb_typeof(public_jwk) = 'object')
);

create unique index if not exists employee_devices_one_active_per_employee
  on public.employee_devices(employee_id) where status = 'active';
create unique index if not exists employee_devices_one_pending_per_employee
  on public.employee_devices(employee_id) where status = 'pending';
create index if not exists employee_devices_employee_created
  on public.employee_devices(employee_id, created_at desc);

create table if not exists public.employee_device_challenges (
  nonce uuid primary key,
  device_id uuid not null references public.employee_devices(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index if not exists employee_device_challenges_expiry
  on public.employee_device_challenges(expires_at);

alter table public.employee_devices enable row level security;
alter table public.employee_device_challenges enable row level security;
revoke all on public.employee_devices from anon, authenticated;
revoke all on public.employee_device_challenges from anon, authenticated;
grant all on public.employee_devices to service_role;
grant all on public.employee_device_challenges to service_role;

create or replace function public.consume_employee_device_challenge(p_nonce uuid, p_device_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.employee_device_challenges
     set used_at = now()
   where nonce = p_nonce
     and device_id = p_device_id
     and used_at is null
     and expires_at > now();
  get diagnostics v_count = row_count;
  return v_count = 1;
end;
$$;
revoke all on function public.consume_employee_device_challenge(uuid, uuid) from public, anon, authenticated;
grant execute on function public.consume_employee_device_challenge(uuid, uuid) to service_role;

-- These PIN-only employee RPCs will be locked down in a separate cutover migration
-- after the device gateway and updated kiosk client have passed smoke tests.
