-- =====================================================================
-- COD TEAM — Migration v10 (Time Tracking pro, style ClickUp)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) Table principale des entrees de temps
create table if not exists public.time_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text default '',
  task_type text not null check (task_type in (
    'call','production','video_edit','sourcing','media_buying',
    'workshop','research','admin','training','meeting','other'
  )),
  related_table text default '',   -- 'orders','products','video_assets','product_tests','creative_tests','workshop_offers'
  related_id uuid,                 -- FK to the related entity (no FK constraint - generic)
  description text default '',
  start_time timestamptz not null default now(),
  end_time timestamptz,            -- null = timer still running
  duration_seconds int default 0,  -- denormalized for fast aggregation
  billable boolean default true,
  is_manual boolean default false,
  source text default 'manual',    -- 'manual','auto_call','auto_status'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists time_entries_user_start_idx on public.time_entries(user_id, start_time desc);
create index if not exists time_entries_related_idx on public.time_entries(related_table, related_id);
create index if not exists time_entries_running_idx on public.time_entries(user_id) where end_time is null;
create index if not exists time_entries_role_idx on public.time_entries(role, start_time desc);

-- 2) Estimates (combien de temps attendu pour un type de tache)
alter table public.products add column if not exists time_estimate_minutes int default 0;
alter table public.video_assets add column if not exists time_estimate_minutes int default 0;
alter table public.tasks add column if not exists time_estimate_minutes int default 0;

-- 3) RLS
alter table public.time_entries enable row level security;
drop policy if exists te_select on public.time_entries;
create policy te_select on public.time_entries for select to authenticated
  using (user_id = auth.uid() or public.my_role() in ('admin'));
drop policy if exists te_insert on public.time_entries;
create policy te_insert on public.time_entries for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists te_update on public.time_entries;
create policy te_update on public.time_entries for update to authenticated
  using (user_id = auth.uid() or public.my_role()='admin')
  with check (user_id = auth.uid() or public.my_role()='admin');
drop policy if exists te_delete on public.time_entries;
create policy te_delete on public.time_entries for delete to authenticated
  using (user_id = auth.uid() or public.my_role()='admin');

-- 4) Trigger updated_at + auto-compute duration
create or replace function public.touch_time_entry() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  if new.end_time is not null then
    new.duration_seconds = greatest(0, extract(epoch from (new.end_time - new.start_time))::int);
  end if;
  return new;
end; $$;
drop trigger if exists time_entries_touch on public.time_entries;
create trigger time_entries_touch before insert or update on public.time_entries
  for each row execute function public.touch_time_entry();

-- 5) Realtime
do $$ begin
  begin alter publication supabase_realtime add table public.time_entries; exception when others then null; end;
end $$;

-- 6) Aggregation views (lecture rapide)
create or replace view public.time_stats_today as
select
  user_id,
  count(*) as entry_count,
  sum(coalesce(duration_seconds, extract(epoch from (now() - start_time))::int)) as total_seconds,
  count(*) filter (where end_time is null) as running_count
from public.time_entries
where start_time >= date_trunc('day', now())
group by user_id;

create or replace view public.time_stats_week as
select
  user_id,
  count(*) as entry_count,
  sum(duration_seconds) as total_seconds
from public.time_entries
where start_time >= date_trunc('week', now())
  and end_time is not null
group by user_id;

-- 7) Helper: arret automatique des timers ouverts depuis plus de 12h (anti-orphelins)
create or replace function public.cleanup_orphan_timers() returns int
language plpgsql security definer as $$
declare cnt int;
begin
  update public.time_entries
  set end_time = start_time + interval '12 hours',
      duration_seconds = 43200,
      description = description || ' [auto-cloturee apres 12h]'
  where end_time is null
    and start_time < now() - interval '12 hours';
  get diagnostics cnt = row_count;
  return cnt;
end; $$;

select 'Migration v10 OK' as status,
  (select count(*) from public.time_entries) as time_entries_count;
