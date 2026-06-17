-- =====================================================================
-- COD TEAM — Migration v11 (Pro Time Management T1-T6)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- ==== T1 : SLAs et discipline operationnelle ====
create table if not exists public.sla_definitions (
  id uuid primary key default gen_random_uuid(),
  role text not null,
  task_type text not null,
  target_hours numeric(8,2) not null,
  alert_threshold_pct int default 80,
  active boolean default true,
  created_at timestamptz default now(),
  unique (role, task_type)
);

-- Seed SLAs par defaut (valeurs ajustables ensuite)
insert into public.sla_definitions (role, task_type, target_hours) values
 ('confirmatrice', 'call', 3),
 ('video_editor', 'video_edit', 48),
 ('production', 'production', 120),
 ('sourcing', 'sourcing', 168),
 ('media_buyer', 'media_buying', 24)
on conflict (role, task_type) do nothing;

-- Colonnes SLA sur tables existantes
alter table public.orders add column if not exists sla_deadline timestamptz;
alter table public.video_assets add column if not exists sla_deadline timestamptz;

-- Trigger : pose sla_deadline a la creation d'une commande
create or replace function public.set_order_sla() returns trigger language plpgsql as $$
declare h numeric;
begin
  select target_hours into h from public.sla_definitions
    where role='confirmatrice' and task_type='call' and active=true;
  if h is not null then
    new.sla_deadline := new.created_at + (h || ' hours')::interval;
  end if;
  return new;
end; $$;
drop trigger if exists set_order_sla_trg on public.orders;
create trigger set_order_sla_trg before insert on public.orders
  for each row execute function public.set_order_sla();

-- Backfill commandes existantes
update public.orders
set sla_deadline = created_at + interval '3 hours'
where sla_deadline is null;

-- ==== T2 : Cout horaire par profile ====
alter table public.profiles add column if not exists hourly_cost_dzd numeric(10,2) default 0;
alter table public.profiles add column if not exists daily_cap_hours int default 9;

-- Vue : cout horaire par commande (agreges les time_entries lies)
create or replace view public.order_labor_cost as
select
  o.id as order_id,
  o.customer_name,
  o.total_price,
  coalesce(sum(
    case when te.duration_seconds > 0 and p.hourly_cost_dzd > 0
    then (te.duration_seconds::numeric / 3600) * p.hourly_cost_dzd
    else 0 end
  ), 0)::numeric(12,2) as labor_cost_dzd,
  count(te.id) as time_entries_count
from public.orders o
left join public.time_entries te on te.related_table='orders' and te.related_id=o.id
left join public.profiles p on p.id=te.user_id
group by o.id, o.customer_name, o.total_price;

-- ==== T5 : Pomodoro (extends time_entries) ====
alter table public.time_entries add column if not exists pomodoro_session boolean default false;
alter table public.time_entries add column if not exists pomodoro_break boolean default false;

-- ==== T6 : Timesheets + paie ====
create table if not exists public.timesheets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  week_start date not null,
  total_seconds int default 0,
  total_labor_dzd numeric(12,2) default 0,
  status text not null default 'draft' check (status in ('draft','submitted','approved','rejected')),
  submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  notes text default '',
  rejection_reason text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, week_start)
);
create index if not exists timesheets_user_idx on public.timesheets(user_id, week_start desc);
create index if not exists timesheets_status_idx on public.timesheets(status);

-- Trigger updated_at
create or replace function public.touch_timesheets() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists timesheets_touch on public.timesheets;
create trigger timesheets_touch before update on public.timesheets
  for each row execute function public.touch_timesheets();

-- ==== RLS ====
alter table public.sla_definitions enable row level security;
drop policy if exists sla_select on public.sla_definitions;
create policy sla_select on public.sla_definitions for select to authenticated using (true);
drop policy if exists sla_iud on public.sla_definitions;
create policy sla_iud on public.sla_definitions for all to authenticated
  using (public.my_role()='admin') with check (public.my_role()='admin');

alter table public.timesheets enable row level security;
drop policy if exists ts_select on public.timesheets;
create policy ts_select on public.timesheets for select to authenticated
  using (user_id = auth.uid() or public.my_role()='admin');
drop policy if exists ts_insert on public.timesheets;
create policy ts_insert on public.timesheets for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists ts_update on public.timesheets;
create policy ts_update on public.timesheets for update to authenticated
  using ((user_id = auth.uid() and status='draft') or public.my_role()='admin')
  with check (true);
drop policy if exists ts_delete on public.timesheets;
create policy ts_delete on public.timesheets for delete to authenticated
  using (public.my_role()='admin');

-- ==== Realtime ====
do $$ begin
  begin alter publication supabase_realtime add table public.sla_definitions; exception when others then null; end;
  begin alter publication supabase_realtime add table public.timesheets; exception when others then null; end;
end $$;

select 'Migration v11 OK' as status,
  (select count(*) from public.sla_definitions) as sla_count;
