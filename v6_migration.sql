-- =====================================================================
-- COD TEAM — Migration v6 (A/B testing creas video)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) Table creative_tests
create table if not exists public.creative_tests (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  creative_name text not null,
  creative_url text default '',
  thumbnail_url text default '',
  platform text default 'meta' check (platform in ('meta','tiktok','snap','google','other')),
  hook_type text default 'ugc',  -- ugc, demo, problem_solution, before_after, lifestyle, expert
  impressions int default 0,
  clicks int default 0,
  spend_usd numeric(10,2) default 0,
  conversions int default 0,
  revenue_dzd numeric(12,2) default 0,
  status text default 'running' check (status in ('running','winner','loser','paused','retest')),
  notes text default '',
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists creative_tests_product_idx on public.creative_tests(product_id);
create index if not exists creative_tests_status_idx on public.creative_tests(status);

-- 2) RLS
alter table public.creative_tests enable row level security;
drop policy if exists ct_select on public.creative_tests;
create policy ct_select on public.creative_tests for select to authenticated using (true);
drop policy if exists ct_insert on public.creative_tests;
create policy ct_insert on public.creative_tests for insert to authenticated with check (public.my_role() in ('admin','media_buyer','video_editor'));
drop policy if exists ct_update on public.creative_tests;
create policy ct_update on public.creative_tests for update to authenticated using (public.my_role() in ('admin','media_buyer','video_editor')) with check (public.my_role() in ('admin','media_buyer','video_editor'));
drop policy if exists ct_delete on public.creative_tests;
create policy ct_delete on public.creative_tests for delete to authenticated using (public.my_role()='admin');

-- 3) Realtime
do $$ begin
  begin alter publication supabase_realtime add table public.creative_tests; exception when others then null; end;
end $$;

-- 4) Trigger updated_at
create or replace function public.touch_creative_tests() returns trigger
language plpgsql as $$
begin new.updated_at=now(); new.updated_by=auth.uid(); return new; end; $$;
drop trigger if exists creative_tests_touch on public.creative_tests;
create trigger creative_tests_touch before update on public.creative_tests
  for each row execute function public.touch_creative_tests();

select 'Migration v6 OK' as status;
