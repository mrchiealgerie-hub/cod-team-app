-- =====================================================================
--  COD TEAM — Bootstrap base (v15)
--  À exécuter en premier sur un projet Supabase neuf ou reconstruit.
--  Puis : v5_migration.sql, puis migrations_combined.sql (v6 → v12).
--
--  Ce fichier couvre les tables de base absentes des migrations :
--  profiles, products, product_sheets, video_assets, tasks, cod_kpis,
--  settings, orders, comments, notifications, audit_log, product_tests,
--  workshop_offers, customer_blacklist.
--
--  Il est idempotent : réexécutable sans perte de données.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 0) Helper générique
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 1) PROFILS & RÔLES
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  full_name        text not null default '',
  role             text not null default 'confirmatrice'
                   check (role in ('admin','media_buyer','video_editor','confirmatrice','production','sourcing')),
  lang             text not null default 'fr' check (lang in ('fr','ar')),
  active           boolean not null default true,
  whatsapp_phone   text not null default '',
  notify_orders    boolean not null default true,
  hourly_cost_dzd  numeric(10,2) not null default 0,
  daily_cap_hours  int not null default 9,
  base_salary_dzd  numeric(10,2) not null default 0,
  variable_pct     numeric(5,2) not null default 20,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Mise à niveau d'une table profiles existante (socle v1).
alter table public.profiles alter column role set default 'confirmatrice';
alter table public.profiles add column if not exists whatsapp_phone   text not null default '';
alter table public.profiles add column if not exists notify_orders    boolean not null default true;
alter table public.profiles add column if not exists hourly_cost_dzd  numeric(10,2) not null default 0;
alter table public.profiles add column if not exists daily_cap_hours  int not null default 9;
alter table public.profiles add column if not exists base_salary_dzd  numeric(10,2) not null default 0;
alter table public.profiles add column if not exists variable_pct     numeric(5,2) not null default 20;
alter table public.profiles add column if not exists updated_at       timestamptz not null default now();

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- Rôle de l'utilisateur connecté (null en SQL Editor / service_role).
create or replace function public.my_role()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select role from public.profiles where id = auth.uid()
$$;

-- Inscription : rôle minimal imposé, quel que soit le rôle envoyé par le client.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role, lang)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    'confirmatrice',
    case when new.raw_user_meta_data->>'lang' = 'ar' then 'ar' else 'fr' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Un utilisateur connecté non-admin ne peut pas modifier son rôle, son état
-- ni sa rémunération. Le SQL Editor / service_role (auth.uid() null) reste autorisé.
create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and coalesce(public.my_role(), '') <> 'admin' then
    new.role             := old.role;
    new.active           := old.active;
    new.hourly_cost_dzd  := old.hourly_cost_dzd;
    new.daily_cap_hours  := old.daily_cap_hours;
    new.base_salary_dzd  := old.base_salary_dzd;
    new.variable_pct     := old.variable_pct;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_privileges_trg on public.profiles;
create trigger protect_profile_privileges_trg
  before update on public.profiles
  for each row execute function public.protect_profile_privileges();

-- ---------------------------------------------------------------------
-- 2) PRODUITS
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  status              text not null default 'idea'
                      check (status in ('idea','sourcing','test_ready','testing','validated','killed','archived')),
  current_stage       text not null default 'idea'
                      check (current_stage in ('idea','research','tovalidate','sourcing','workshop','testing','validated','production','scaling','video','live','killed')),
  niche               text not null default '',
  priority            text not null default 'normal'
                      check (priority in ('low','normal','high','urgent')),
  source              text not null default '',
  keyword             text not null default '',
  concurrent          text not null default '',
  link_alibaba        text not null default '',
  link_site           text not null default '',
  image_url           text not null default '',
  notes               text not null default '',
  usd_to_dzd          numeric(12,2) not null default 260,
  cost_product_usd    numeric(12,2) not null default 0,
  ship_cost_usd       numeric(12,2) not null default 0,
  price_min           numeric(12,2) not null default 0,
  price_final         numeric(12,2) not null default 0,
  multiplier          numeric(8,2)  not null default 3,
  capacity            int not null default 0,
  stock_current       int not null default 0,
  stock_min           int not null default 50,
  wow_score           numeric(4,1) not null default 0,
  problem_score       numeric(4,1) not null default 0,
  before_after_score  numeric(4,1) not null default 0,
  innovation_score    numeric(4,1) not null default 0,
  final_score         numeric(4,1) not null default 0,
  time_estimate_minutes int not null default 0,
  validated_at        timestamptz,
  validated_by        uuid references public.profiles(id) on delete set null,
  created_by          uuid references public.profiles(id) on delete set null,
  deleted_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- Colonnes héritées du socle v1 (conservées pour compatibilité)
  supplier            text not null default '',
  cost_buy            numeric(12,2) not null default 0,
  price_sell          numeric(12,2) not null default 0,
  shipping_cost       numeric(12,2) not null default 0,
  test_budget         numeric(12,2) not null default 0,
  verdict             text not null default '' check (verdict in ('','validate','kill','pending')),
  owner_id            uuid references public.profiles(id) on delete set null
);

-- Mise à niveau d'une table products existante (socle v1).
alter table public.products add column if not exists current_stage       text not null default 'idea';
alter table public.products add column if not exists niche               text not null default '';
alter table public.products add column if not exists priority            text not null default 'normal';
alter table public.products add column if not exists source              text not null default '';
alter table public.products add column if not exists keyword             text not null default '';
alter table public.products add column if not exists concurrent          text not null default '';
alter table public.products add column if not exists link_alibaba        text not null default '';
alter table public.products add column if not exists link_site           text not null default '';
alter table public.products add column if not exists usd_to_dzd          numeric(12,2) not null default 260;
alter table public.products add column if not exists cost_product_usd    numeric(12,2) not null default 0;
alter table public.products add column if not exists ship_cost_usd       numeric(12,2) not null default 0;
alter table public.products add column if not exists price_min           numeric(12,2) not null default 0;
alter table public.products add column if not exists price_final         numeric(12,2) not null default 0;
alter table public.products add column if not exists multiplier          numeric(8,2)  not null default 3;
alter table public.products add column if not exists stock_current       int not null default 0;
alter table public.products add column if not exists stock_min           int not null default 50;
alter table public.products add column if not exists wow_score           numeric(4,1) not null default 0;
alter table public.products add column if not exists problem_score       numeric(4,1) not null default 0;
alter table public.products add column if not exists before_after_score  numeric(4,1) not null default 0;
alter table public.products add column if not exists innovation_score    numeric(4,1) not null default 0;
alter table public.products add column if not exists final_score         numeric(4,1) not null default 0;
alter table public.products add column if not exists time_estimate_minutes int not null default 0;
alter table public.products add column if not exists validated_at        timestamptz;
alter table public.products add column if not exists validated_by        uuid references public.profiles(id) on delete set null;
alter table public.products add column if not exists created_by          uuid references public.profiles(id) on delete set null;
alter table public.products add column if not exists deleted_at          timestamptz;

-- Contraintes de statut (ignorées si une ancienne contrainte incompatible existe).
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass and conname = 'products_current_stage_check') then
    begin
      alter table public.products add constraint products_current_stage_check
        check (current_stage in ('idea','research','tovalidate','sourcing','workshop','testing','validated','production','scaling','video','live','killed'));
    exception when others then null;
    end;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass and conname = 'products_priority_check') then
    begin
      alter table public.products add constraint products_priority_check
        check (priority in ('low','normal','high','urgent'));
    exception when others then null;
    end;
  end if;
end $$;

drop trigger if exists touch_products on public.products;
create trigger touch_products before update on public.products
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 3) RÉGLAGES (key/value)
-- ---------------------------------------------------------------------
create table if not exists public.settings (
  key         text primary key,
  value       jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id) on delete set null
);

-- Lecture numérique robuste d'un réglage stocké en jsonb ou en text.
create or replace function public.setting_number(p_key text, p_default numeric default 0)
returns numeric
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v numeric;
begin
  select nullif(trim(both '"' from value::text), '')::numeric
    into v
    from public.settings
   where key = p_key;
  return coalesce(v, p_default);
exception when others then
  return p_default;
end;
$$;

-- Valeurs de repli déjà codées dans l'application.
insert into public.settings (key, value) values
  ('usd_to_dzd',            '260'::jsonb),
  ('default_confirm_rate',  '70'::jsonb),
  ('default_deliver_rate',  '60'::jsonb),
  ('min_margin_threshold',  '500'::jsonb),
  ('weight_wow',            '1'::jsonb),
  ('weight_problem',        '1'::jsonb),
  ('weight_before_after',   '1'::jsonb),
  ('weight_innovation',     '1'::jsonb)
on conflict (key) do nothing;

-- Score final = moyenne pondérée des 4 critères.
-- Les poids sont modifiables dans Réglages ; un simple UPDATE de products
-- (même sur updated_at) déclenche le recalcul, comme le fait l'application.
create or replace function public.recalc_final_score()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  w_wow numeric := public.setting_number('weight_wow', 1);
  w_problem numeric := public.setting_number('weight_problem', 1);
  w_ba numeric := public.setting_number('weight_before_after', 1);
  w_innov numeric := public.setting_number('weight_innovation', 1);
  total_w numeric;
begin
  total_w := coalesce(w_wow,0) + coalesce(w_problem,0) + coalesce(w_ba,0) + coalesce(w_innov,0);
  if total_w <= 0 then
    new.final_score := 0;
  else
    new.final_score := round((
      coalesce(new.wow_score,0) * coalesce(w_wow,0) +
      coalesce(new.problem_score,0) * coalesce(w_problem,0) +
      coalesce(new.before_after_score,0) * coalesce(w_ba,0) +
      coalesce(new.innovation_score,0) * coalesce(w_innov,0)
    ) / total_w, 1);
  end if;
  return new;
end;
$$;

drop trigger if exists recalc_final_score_trg on public.products;
create trigger recalc_final_score_trg
  before insert or update on public.products
  for each row execute function public.recalc_final_score();

-- ---------------------------------------------------------------------
-- 4) FICHES PRODUIT & VIDÉOS
-- ---------------------------------------------------------------------
create table if not exists public.product_sheets (
  product_id  uuid primary key references public.products(id) on delete cascade,
  call_script text not null default '',
  objections  text not null default '',
  upsells     text not null default '',
  faq         text not null default '',
  updated_at  timestamptz not null default now()
);

drop trigger if exists touch_sheets on public.product_sheets;
create trigger touch_sheets before update on public.product_sheets
  for each row execute function public.touch_updated_at();

create table if not exists public.video_assets (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid references public.products(id) on delete cascade,
  title       text not null,
  kind        text not null default 'ugc',
  status      text not null default 'todo' check (status in ('todo','in_progress','review','done')),
  assignee_id uuid references public.profiles(id) on delete set null,
  link_url    text not null default '',
  time_estimate_minutes int not null default 0,
  sla_deadline timestamptz,
  created_at  timestamptz not null default now()
);

alter table public.video_assets add column if not exists time_estimate_minutes int not null default 0;
alter table public.video_assets add column if not exists sla_deadline timestamptz;

-- ---------------------------------------------------------------------
-- 5) TÂCHES & KPIs
-- ---------------------------------------------------------------------
create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  description text not null default '',
  assignee_id uuid references public.profiles(id) on delete set null,
  created_by  uuid references public.profiles(id) on delete set null,
  product_id  uuid references public.products(id) on delete set null,
  priority    text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status      text not null default 'todo' check (status in ('todo','doing','done')),
  due_date    date,
  time_estimate_minutes int not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.tasks add column if not exists time_estimate_minutes int not null default 0;

create table if not exists public.cod_kpis (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid references public.products(id) on delete cascade,
  day         date not null default current_date,
  orders      integer not null default 0,
  confirmed   integer not null default 0,
  delivered   integer not null default 0,
  returned    integer not null default 0,
  revenue     numeric(12,2) not null default 0,
  ad_spend    numeric(12,2) not null default 0,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6) COMMANDES COD / CALL CENTER
-- ---------------------------------------------------------------------
create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  product_id       uuid references public.products(id) on delete set null,
  customer_name    text not null default '',
  customer_phone   text not null,
  customer_wilaya  text not null default '',
  wilaya_code      int,
  customer_address text not null default '',
  quantity         int not null default 1,
  unit_price       numeric(12,2) not null default 0,
  shipping_cost    numeric(12,2) not null default 0,
  total_price      numeric(12,2) not null default 0,
  status           text not null default 'queued'
                   check (status in ('queued','calling','confirmed','reschedule','no_answer','refused','fake','cancelled','delivered','returned')),
  assignee_id      uuid references public.profiles(id) on delete set null,
  notes            text not null default '',
  last_call_at     timestamptz,
  call_attempts    int not null default 0,
  fake_reversed    boolean not null default false,
  sla_deadline     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Mise à niveau d'une table orders existante.
alter table public.orders add column if not exists product_id       uuid references public.products(id) on delete set null;
alter table public.orders add column if not exists customer_name    text not null default '';
alter table public.orders add column if not exists customer_phone   text;
alter table public.orders add column if not exists customer_wilaya  text not null default '';
alter table public.orders add column if not exists wilaya_code      int;
alter table public.orders add column if not exists customer_address text not null default '';
alter table public.orders add column if not exists quantity         int not null default 1;
alter table public.orders add column if not exists unit_price       numeric(12,2) not null default 0;
alter table public.orders add column if not exists shipping_cost    numeric(12,2) not null default 0;
alter table public.orders add column if not exists total_price      numeric(12,2) not null default 0;
alter table public.orders add column if not exists assignee_id      uuid references public.profiles(id) on delete set null;
alter table public.orders add column if not exists notes            text not null default '';
alter table public.orders add column if not exists last_call_at     timestamptz;
alter table public.orders add column if not exists call_attempts    int not null default 0;
alter table public.orders add column if not exists fake_reversed    boolean not null default false;
alter table public.orders add column if not exists sla_deadline     timestamptz;
alter table public.orders add column if not exists updated_at       timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.orders'::regclass and conname = 'orders_status_check') then
    begin
      alter table public.orders add constraint orders_status_check
        check (status in ('queued','calling','confirmed','reschedule','no_answer','refused','fake','cancelled','delivered','returned'));
    exception when others then null;
    end;
  end if;
end $$;

drop trigger if exists touch_orders on public.orders;
create trigger touch_orders before update on public.orders
  for each row execute function public.touch_updated_at();

create index if not exists orders_status_created_idx on public.orders(status, created_at desc);
create index if not exists orders_assignee_idx on public.orders(assignee_id);
create index if not exists orders_phone_idx on public.orders(customer_phone);
create index if not exists orders_product_idx on public.orders(product_id);

-- ---------------------------------------------------------------------
-- 7) COMMENTAIRES, NOTIFICATIONS, AUDIT
-- ---------------------------------------------------------------------
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.products(id) on delete cascade,
  user_id     uuid references public.profiles(id) on delete set null,
  body        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists comments_product_idx on public.comments(product_id, created_at);

create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null default 'info',
  title       text not null,
  body        text not null default '',
  link        text not null default '',
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications(user_id) where read = false;

create table if not exists public.audit_log (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references public.profiles(id) on delete set null,
  table_name  text not null,
  record_id   uuid,
  action      text not null,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists audit_record_idx on public.audit_log(record_id, created_at desc);
create index if not exists audit_table_idx on public.audit_log(table_name, created_at desc);
alter table public.audit_log alter column record_id drop not null;

-- ---------------------------------------------------------------------
-- 8) TESTS PRODUIT, OFFRES ATELIER, BLACKLIST
-- ---------------------------------------------------------------------
create table if not exists public.product_tests (
  id                uuid primary key default gen_random_uuid(),
  product_id        uuid not null references public.products(id) on delete cascade,
  tester_id         uuid references public.profiles(id) on delete set null,
  platform          text not null default 'meta' check (platform in ('meta','tiktok','snap','google','other')),
  budget_usd        numeric(10,2) not null default 0,
  cpa_usd           numeric(10,2) not null default 0,
  confirm_pct       numeric(5,2) not null default 0,
  deliver_pct       numeric(5,2) not null default 0,
  calculated_margin numeric(12,2) not null default 0,
  verdict           text not null default 'pending' check (verdict in ('pending','validate','iterate','kill')),
  notes             text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists product_tests_product_idx on public.product_tests(product_id, created_at desc);

drop trigger if exists touch_product_tests on public.product_tests;
create trigger touch_product_tests before update on public.product_tests
  for each row execute function public.touch_updated_at();

create table if not exists public.workshop_offers (
  id                  uuid primary key default gen_random_uuid(),
  product_id          uuid not null references public.products(id) on delete cascade,
  workshop_id         uuid references public.profiles(id) on delete set null,
  workshop_name       text not null default '',
  price_dzd           numeric(12,2) not null default 0,
  ease                int not null default 5,
  delay_days          int not null default 0,
  capacity_per_month  int not null default 0,
  notes               text not null default '',
  chosen              boolean not null default false,
  status              text not null default 'pending' check (status in ('pending','chosen','rejected')),
  created_at          timestamptz not null default now()
);
create index if not exists workshop_offers_product_idx on public.workshop_offers(product_id, created_at desc);

create table if not exists public.customer_blacklist (
  phone       text primary key,
  reason      text not null default '',
  added_by    uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 9) ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.products            enable row level security;
alter table public.product_sheets      enable row level security;
alter table public.video_assets        enable row level security;
alter table public.tasks               enable row level security;
alter table public.cod_kpis            enable row level security;
alter table public.settings            enable row level security;
alter table public.orders              enable row level security;
alter table public.comments            enable row level security;
alter table public.notifications       enable row level security;
alter table public.audit_log           enable row level security;
alter table public.product_tests       enable row level security;
alter table public.workshop_offers     enable row level security;
alter table public.customer_blacklist  enable row level security;

-- PROFILES
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- PRODUCTS
drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated using (true);
drop policy if exists products_write on public.products;
create policy products_write on public.products for insert to authenticated
  with check (public.my_role() in ('admin','sourcing','media_buyer'));
drop policy if exists products_update on public.products;
create policy products_update on public.products for update to authenticated
  using (public.my_role() in ('admin','sourcing','media_buyer'))
  with check (public.my_role() in ('admin','sourcing','media_buyer'));
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete to authenticated
  using (public.my_role() = 'admin');

-- PRODUCT SHEETS
drop policy if exists sheets_select on public.product_sheets;
create policy sheets_select on public.product_sheets for select to authenticated using (true);
drop policy if exists sheets_write on public.product_sheets;
create policy sheets_write on public.product_sheets for insert to authenticated
  with check (public.my_role() in ('admin','sourcing','media_buyer'));
drop policy if exists sheets_update on public.product_sheets;
create policy sheets_update on public.product_sheets for update to authenticated
  using (public.my_role() in ('admin','sourcing','media_buyer'))
  with check (public.my_role() in ('admin','sourcing','media_buyer'));
drop policy if exists sheets_delete on public.product_sheets;
create policy sheets_delete on public.product_sheets for delete to authenticated
  using (public.my_role() = 'admin');

-- VIDEO ASSETS
drop policy if exists video_select on public.video_assets;
create policy video_select on public.video_assets for select to authenticated using (true);
drop policy if exists video_write on public.video_assets;
create policy video_write on public.video_assets for insert to authenticated
  with check (public.my_role() in ('admin','media_buyer','video_editor'));
drop policy if exists video_update on public.video_assets;
create policy video_update on public.video_assets for update to authenticated
  using (public.my_role() in ('admin','media_buyer','video_editor') or assignee_id = auth.uid())
  with check (public.my_role() in ('admin','media_buyer','video_editor') or assignee_id = auth.uid());
drop policy if exists video_delete on public.video_assets;
create policy video_delete on public.video_assets for delete to authenticated
  using (public.my_role() = 'admin');

-- TASKS
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated
  using (assignee_id = auth.uid() or created_by = auth.uid() or public.my_role() = 'admin');
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated
  with check (created_by = auth.uid());
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated
  using (assignee_id = auth.uid() or created_by = auth.uid() or public.my_role() in ('admin','media_buyer'))
  with check (assignee_id = auth.uid() or created_by = auth.uid() or public.my_role() in ('admin','media_buyer'));
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated
  using (created_by = auth.uid() or public.my_role() = 'admin');

-- COD KPIS
drop policy if exists kpis_select on public.cod_kpis;
create policy kpis_select on public.cod_kpis for select to authenticated using (true);
drop policy if exists kpis_write on public.cod_kpis;
create policy kpis_write on public.cod_kpis for insert to authenticated
  with check (public.my_role() in ('admin','media_buyer'));
drop policy if exists kpis_update on public.cod_kpis;
create policy kpis_update on public.cod_kpis for update to authenticated
  using (public.my_role() in ('admin','media_buyer'))
  with check (public.my_role() in ('admin','media_buyer'));
drop policy if exists kpis_delete on public.cod_kpis;
create policy kpis_delete on public.cod_kpis for delete to authenticated
  using (public.my_role() in ('admin','media_buyer'));

-- SETTINGS
drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings for select to authenticated using (true);
drop policy if exists settings_admin on public.settings;
create policy settings_admin on public.settings for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- ORDERS
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated using (true);
drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders for insert to authenticated
  with check (public.my_role() in ('admin','confirmatrice','media_buyer'));
drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders for update to authenticated
  using (public.my_role() in ('admin','confirmatrice','media_buyer'))
  with check (public.my_role() in ('admin','confirmatrice','media_buyer'));
drop policy if exists orders_delete on public.orders;
create policy orders_delete on public.orders for delete to authenticated
  using (public.my_role() = 'admin');

-- COMMENTS
drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments for select to authenticated using (true);
drop policy if exists comments_insert on public.comments;
create policy comments_insert on public.comments for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments for delete to authenticated
  using (user_id = auth.uid() or public.my_role() = 'admin');

-- NOTIFICATIONS
drop policy if exists notif_select on public.notifications;
create policy notif_select on public.notifications for select to authenticated
  using (user_id = auth.uid() or public.my_role() = 'admin');
drop policy if exists notif_insert on public.notifications;
create policy notif_insert on public.notifications for insert to authenticated
  with check (true);
drop policy if exists notif_update on public.notifications;
create policy notif_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists notif_delete on public.notifications;
create policy notif_delete on public.notifications for delete to authenticated
  using (user_id = auth.uid() or public.my_role() = 'admin');

-- AUDIT LOG (lecture + écriture, jamais de modification)
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated using (true);
drop policy if exists audit_insert on public.audit_log;
create policy audit_insert on public.audit_log for insert to authenticated
  with check (user_id = auth.uid() or user_id is null);

-- PRODUCT TESTS
drop policy if exists pt_select on public.product_tests;
create policy pt_select on public.product_tests for select to authenticated using (true);
drop policy if exists pt_insert on public.product_tests;
create policy pt_insert on public.product_tests for insert to authenticated
  with check (public.my_role() in ('admin','media_buyer'));
drop policy if exists pt_update on public.product_tests;
create policy pt_update on public.product_tests for update to authenticated
  using (public.my_role() in ('admin','media_buyer') or tester_id = auth.uid())
  with check (public.my_role() in ('admin','media_buyer') or tester_id = auth.uid());
drop policy if exists pt_delete on public.product_tests;
create policy pt_delete on public.product_tests for delete to authenticated
  using (public.my_role() = 'admin' or tester_id = auth.uid());

-- WORKSHOP OFFERS
drop policy if exists wo_select on public.workshop_offers;
create policy wo_select on public.workshop_offers for select to authenticated using (true);
drop policy if exists wo_insert on public.workshop_offers;
create policy wo_insert on public.workshop_offers for insert to authenticated
  with check (public.my_role() in ('admin','sourcing','production'));
drop policy if exists wo_update on public.workshop_offers;
create policy wo_update on public.workshop_offers for update to authenticated
  using (public.my_role() in ('admin','sourcing','production'))
  with check (public.my_role() in ('admin','sourcing','production'));
drop policy if exists wo_delete on public.workshop_offers;
create policy wo_delete on public.workshop_offers for delete to authenticated
  using (public.my_role() in ('admin','sourcing','production'));

-- CUSTOMER BLACKLIST
drop policy if exists bl_select on public.customer_blacklist;
create policy bl_select on public.customer_blacklist for select to authenticated using (true);
drop policy if exists bl_insert on public.customer_blacklist;
create policy bl_insert on public.customer_blacklist for insert to authenticated
  with check (public.my_role() in ('admin','confirmatrice','media_buyer'));
drop policy if exists bl_update on public.customer_blacklist;
create policy bl_update on public.customer_blacklist for update to authenticated
  using (public.my_role() in ('admin','confirmatrice'))
  with check (public.my_role() in ('admin','confirmatrice'));
drop policy if exists bl_delete on public.customer_blacklist;
create policy bl_delete on public.customer_blacklist for delete to authenticated
  using (public.my_role() in ('admin','confirmatrice'));

-- ---------------------------------------------------------------------
-- 10) DROITS & REALTIME
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to authenticated, service_role;

alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant execute on functions to authenticated;
alter default privileges in schema public grant all on tables to service_role;

-- Les notifications sont filtrées par user_id côté client : réplique complète requise.
alter table public.notifications replica identity full;
alter table public.orders replica identity full;

do $$
begin
  begin alter publication supabase_realtime add table public.profiles;           exception when others then null; end;
  begin alter publication supabase_realtime add table public.products;           exception when others then null; end;
  begin alter publication supabase_realtime add table public.product_sheets;     exception when others then null; end;
  begin alter publication supabase_realtime add table public.video_assets;       exception when others then null; end;
  begin alter publication supabase_realtime add table public.tasks;              exception when others then null; end;
  begin alter publication supabase_realtime add table public.cod_kpis;           exception when others then null; end;
  begin alter publication supabase_realtime add table public.settings;           exception when others then null; end;
  begin alter publication supabase_realtime add table public.orders;             exception when others then null; end;
  begin alter publication supabase_realtime add table public.comments;           exception when others then null; end;
  begin alter publication supabase_realtime add table public.notifications;      exception when others then null; end;
  begin alter publication supabase_realtime add table public.audit_log;          exception when others then null; end;
  begin alter publication supabase_realtime add table public.product_tests;      exception when others then null; end;
  begin alter publication supabase_realtime add table public.workshop_offers;    exception when others then null; end;
  begin alter publication supabase_realtime add table public.customer_blacklist; exception when others then null; end;
end $$;

-- ---------------------------------------------------------------------
-- 11) STORAGE (bucket public "media")
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public)
    values ('media', 'media', true)
    on conflict (id) do nothing;

    begin
      drop policy if exists "media_public_read" on storage.objects;
      create policy "media_public_read" on storage.objects
        for select using (bucket_id = 'media');
    exception when others then null; end;

    begin
      drop policy if exists "media_auth_insert" on storage.objects;
      create policy "media_auth_insert" on storage.objects
        for insert to authenticated with check (bucket_id = 'media');
    exception when others then null; end;

    begin
      drop policy if exists "media_auth_update" on storage.objects;
      create policy "media_auth_update" on storage.objects
        for update to authenticated using (bucket_id = 'media');
    exception when others then null; end;

    begin
      drop policy if exists "media_auth_delete" on storage.objects;
      create policy "media_auth_delete" on storage.objects
        for delete to authenticated using (bucket_id = 'media');
    exception when others then null; end;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 12) RECALCUL DES SCORES EXISTANTS
-- ---------------------------------------------------------------------
update public.products set updated_at = now() where deleted_at is null;

select 'Bootstrap base OK' as status,
       (select count(*) from public.products)   as products,
       (select count(*) from public.orders)     as orders,
       (select count(*) from public.settings)   as settings;
