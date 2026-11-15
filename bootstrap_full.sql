-- =====================================================================
--  COD TEAM — Bootstrap complet (v15)
--  UN SEUL COLLAGE : Supabase Dashboard -> SQL Editor -> New query -> Run
--
--  Contenu, dans l'ordre :
--    1. Socle de base (14 tables) .............. bootstrap_base.sql
--    2. Migration v5 (wilayas, stock, top 5) ... v5_migration.sql
--    3. Migrations v6 -> v12 ................... migrations_combined.sql
--
--  Idempotent : réexécutable sans perte de données.
--  Sur un projet neuf, l'exécution prend quelques secondes à une minute
--  selon la charge du projet.
--
--  Après exécution :
--    - créer le premier compte via l'écran d'inscription de l'app
--      (le compte naît "confirmatrice"), puis se promouvoir admin :
--        update public.profiles set role='admin'
--         where id = (select id from auth.users where email='VOTRE_EMAIL');
--    - lire RECOVERY_SUPABASE.md pour la suite (clés API, Storage, Realtime).
-- =====================================================================

-- ===================== 1/3 — SOCLE DE BASE ==========================

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

-- #####################################################################
-- #  2/3 — MIGRATION v5 : WILAYAS, STOCK, TOP 5
-- #####################################################################

-- =====================================================================
-- COD TEAM — Migration v5 (Top 5 Strategique)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) WILAYAS (58 wilayas DZ)
create table if not exists public.wilayas (
  code int primary key,
  name_fr text not null,
  name_ar text not null,
  zone int default 1, -- 1=Nord, 2=Hauts-plateaux Est, 3=Hauts-plateaux/Sud, 4=Grand Sud
  yalidine_rate numeric(8,2) default 500,
  zrexpress_rate numeric(8,2) default 550,
  maystro_rate numeric(8,2) default 500
);
alter table public.wilayas enable row level security;
drop policy if exists wilayas_select on public.wilayas;
create policy wilayas_select on public.wilayas for select to authenticated using (true);
drop policy if exists wilayas_admin on public.wilayas;
create policy wilayas_admin on public.wilayas for all to authenticated using (public.my_role()='admin') with check (public.my_role()='admin');

-- 2) Colonnes stock sur products
alter table public.products add column if not exists stock_current int default 0;
alter table public.products add column if not exists stock_min int default 50;

-- 3) Colonnes wilaya + frais sur orders
alter table public.orders add column if not exists wilaya_code int;
alter table public.orders add column if not exists shipping_cost numeric(12,2) default 0;

-- 4) Mouvements de stock
create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  movement_type text not null check (movement_type in ('in','out','adjustment')),
  quantity int not null,
  reason text default '',
  notes text default '',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.stock_movements enable row level security;
drop policy if exists sm_select on public.stock_movements;
create policy sm_select on public.stock_movements for select to authenticated using (true);
drop policy if exists sm_insert on public.stock_movements;
create policy sm_insert on public.stock_movements for insert to authenticated with check (public.my_role() in ('admin','production'));

-- 5) Trigger appliquant le mouvement de stock sur products
create or replace function public.apply_stock_movement() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.movement_type='in' then
    update public.products set stock_current = coalesce(stock_current,0) + new.quantity where id = new.product_id;
  elsif new.movement_type='out' then
    update public.products set stock_current = coalesce(stock_current,0) - new.quantity where id = new.product_id;
  elsif new.movement_type='adjustment' then
    update public.products set stock_current = new.quantity where id = new.product_id;
  end if;
  return new;
end; $$;
drop trigger if exists apply_stock_trg on public.stock_movements;
create trigger apply_stock_trg after insert on public.stock_movements
  for each row execute function public.apply_stock_movement();

-- 6) Realtime
do $$ begin
  begin alter publication supabase_realtime add table public.wilayas; exception when others then null; end;
  begin alter publication supabase_realtime add table public.stock_movements; exception when others then null; end;
end $$;

-- 7) Seed 58 wilayas avec tarifs Yalidine/ZRexpress/Maystro
insert into public.wilayas (code, name_fr, name_ar, zone, yalidine_rate, zrexpress_rate, maystro_rate) values
 (1,'Adrar','أدرار',4,1400,1400,1400),
 (2,'Chlef','الشلف',1,500,500,500),
 (3,'Laghouat','الأغواط',3,700,700,700),
 (4,'Oum El Bouaghi','أم البواقي',2,600,600,600),
 (5,'Batna','باتنة',2,600,600,600),
 (6,'Bejaia','بجاية',1,550,550,550),
 (7,'Biskra','بسكرة',3,700,700,700),
 (8,'Bechar','بشار',4,1100,1100,1100),
 (9,'Blida','البليدة',1,400,400,400),
 (10,'Bouira','البويرة',1,500,500,500),
 (11,'Tamanrasset','تمنراست',4,1500,1500,1500),
 (12,'Tebessa','تبسة',2,650,650,650),
 (13,'Tlemcen','تلمسان',1,650,650,650),
 (14,'Tiaret','تيارت',3,600,600,600),
 (15,'Tizi Ouzou','تيزي وزو',1,500,500,500),
 (16,'Alger','الجزائر',1,400,400,400),
 (17,'Djelfa','الجلفة',3,650,650,650),
 (18,'Jijel','جيجل',1,550,550,550),
 (19,'Setif','سطيف',2,550,550,550),
 (20,'Saida','سعيدة',3,700,700,700),
 (21,'Skikda','سكيكدة',1,550,550,550),
 (22,'Sidi Bel Abbes','سيدي بلعباس',1,650,650,650),
 (23,'Annaba','عنابة',1,600,600,600),
 (24,'Guelma','قالمة',1,600,600,600),
 (25,'Constantine','قسنطينة',1,550,550,550),
 (26,'Medea','المدية',1,500,500,500),
 (27,'Mostaganem','مستغانم',1,550,550,550),
 (28,'M''Sila','المسيلة',3,650,650,650),
 (29,'Mascara','معسكر',1,650,650,650),
 (30,'Ouargla','ورقلة',3,900,900,900),
 (31,'Oran','وهران',1,600,600,600),
 (32,'El Bayadh','البيض',4,900,900,900),
 (33,'Illizi','إيليزي',4,1500,1500,1500),
 (34,'Bordj Bou Arreridj','برج بوعريريج',2,550,550,550),
 (35,'Boumerdes','بومرداس',1,400,400,400),
 (36,'El Tarf','الطارف',1,650,650,650),
 (37,'Tindouf','تندوف',4,1500,1500,1500),
 (38,'Tissemsilt','تيسمسيلت',3,650,650,650),
 (39,'El Oued','الوادي',3,800,800,800),
 (40,'Khenchela','خنشلة',2,650,650,650),
 (41,'Souk Ahras','سوق أهراس',2,650,650,650),
 (42,'Tipaza','تيبازة',1,450,450,450),
 (43,'Mila','ميلة',1,600,600,600),
 (44,'Ain Defla','عين الدفلى',1,500,500,500),
 (45,'Naama','النعامة',4,900,900,900),
 (46,'Ain Temouchent','عين تموشنت',1,650,650,650),
 (47,'Ghardaia','غرداية',3,800,800,800),
 (48,'Relizane','غليزان',1,600,600,600),
 (49,'Timimoun','تيميمون',4,1400,1400,1400),
 (50,'Bordj Badji Mokhtar','برج باجي مختار',4,1600,1600,1600),
 (51,'Ouled Djellal','أولاد جلال',3,750,750,750),
 (52,'Beni Abbes','بني عباس',4,1200,1200,1200),
 (53,'In Salah','عين صالح',4,1500,1500,1500),
 (54,'In Guezzam','عين قزام',4,1600,1600,1600),
 (55,'Touggourt','تقرت',3,800,800,800),
 (56,'Djanet','جانت',4,1500,1500,1500),
 (57,'El M''Ghair','المغير',3,800,800,800),
 (58,'El Meniaa','المنيعة',4,900,900,900)
on conflict (code) do nothing;

-- Termine
select 'Migration v5 OK' as status, (select count(*) from public.wilayas) as wilayas_count;

-- #####################################################################
-- #  3/3 — MIGRATIONS v6 → v12
-- #####################################################################

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


-- =====================================================================
-- COD TEAM — Migration v7 (Notifications WhatsApp)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) Ajouter WhatsApp + preferences sur profiles
alter table public.profiles add column if not exists whatsapp_phone text default '';
alter table public.profiles add column if not exists notify_orders boolean default true;

-- 2) Templates WhatsApp dans settings (utiliser la table existante)
insert into public.settings (key,value,updated_at) values
 ('whatsapp_template_customer',
  '{"text":"Bonjour {name}, c''est COD Team. Je vous appelle pour confirmer votre commande de {product} a {price} DA. Pouvez-vous repondre ?"}',
  now())
on conflict (key) do nothing;
insert into public.settings (key,value,updated_at) values
 ('whatsapp_template_confirmer',
  '{"text":"🔔 Nouvelle commande COD a confirmer : {name} ({phone}) - {product} - {price} DA - {wilaya}"}',
  now())
on conflict (key) do nothing;

select 'Migration v7 OK' as status;


-- =====================================================================
-- COD TEAM — Migration v8 (WhatsApp CRM: broadcasts + inbox + AI agent)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) Campagnes WhatsApp
create table if not exists public.wa_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  message_template text not null,
  audience_type text default 'segment' check (audience_type in ('segment','phones','all_clients','csv')),
  audience_filter jsonb default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft','running','paused','completed','cancelled')),
  total_recipients int default 0,
  sent_count int default 0,
  failed_count int default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz
);
create index if not exists wa_camp_status_idx on public.wa_campaigns(status);

-- 2) Destinataires d'une campagne
create table if not exists public.wa_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid references public.wa_campaigns(id) on delete cascade,
  phone text not null,
  customer_name text default '',
  rendered_message text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed','replied','skipped')),
  sent_at timestamptz,
  sent_by uuid references public.profiles(id) on delete set null,
  reply_text text default '',
  error_msg text default '',
  position_in_queue int default 0
);
create index if not exists wa_recip_campaign_idx on public.wa_campaign_recipients(campaign_id,status);
create index if not exists wa_recip_phone_idx on public.wa_campaign_recipients(phone);

-- 3) Conversations (inbox manuel)
create table if not exists public.wa_conversations (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,
  customer_name text default '',
  last_message_text text default '',
  last_message_at timestamptz default now(),
  unread_count int default 0,
  status text default 'open' check (status in ('open','pending','closed','archived')),
  assignee_id uuid references public.profiles(id) on delete set null,
  tags text[] default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists wa_conv_status_idx on public.wa_conversations(status);
create index if not exists wa_conv_assignee_idx on public.wa_conversations(assignee_id);

-- 4) Messages dans une conversation
create table if not exists public.wa_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.wa_conversations(id) on delete cascade,
  direction text not null check (direction in ('inbound','outbound')),
  body text not null,
  sent_via text default 'manual' check (sent_via in ('manual','wa_link','api','agent')),
  sender_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists wa_msg_conv_idx on public.wa_messages(conversation_id,created_at);

-- 5) Agent IA: flux declencheur -> reponse
create table if not exists public.wa_agent_flows (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  trigger_type text not null default 'keyword' check (trigger_type in ('keyword','intent','any')),
  trigger_value text default '',
  match_type text default 'contains' check (match_type in ('contains','equals','starts_with','regex')),
  case_sensitive boolean default false,
  language text default 'fr',
  response_template text not null,
  suggested_action text default '' check (suggested_action in ('','confirm_order','mark_refused','mark_reschedule','request_info','send_faq')),
  priority int default 5,
  active boolean default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists wa_flow_active_idx on public.wa_agent_flows(active,priority desc);

-- 6) RLS
alter table public.wa_campaigns enable row level security;
alter table public.wa_campaign_recipients enable row level security;
alter table public.wa_conversations enable row level security;
alter table public.wa_messages enable row level security;
alter table public.wa_agent_flows enable row level security;

drop policy if exists wac_select on public.wa_campaigns;
create policy wac_select on public.wa_campaigns for select to authenticated using (true);
drop policy if exists wac_iud on public.wa_campaigns;
create policy wac_iud on public.wa_campaigns for all to authenticated using (public.my_role() in ('admin','media_buyer')) with check (public.my_role() in ('admin','media_buyer'));

drop policy if exists war_select on public.wa_campaign_recipients;
create policy war_select on public.wa_campaign_recipients for select to authenticated using (true);
drop policy if exists war_iud on public.wa_campaign_recipients;
create policy war_iud on public.wa_campaign_recipients for all to authenticated using (public.my_role() in ('admin','media_buyer','confirmatrice')) with check (public.my_role() in ('admin','media_buyer','confirmatrice'));

drop policy if exists waco_select on public.wa_conversations;
create policy waco_select on public.wa_conversations for select to authenticated using (true);
drop policy if exists waco_iud on public.wa_conversations;
create policy waco_iud on public.wa_conversations for all to authenticated using (public.my_role() in ('admin','confirmatrice','media_buyer')) with check (public.my_role() in ('admin','confirmatrice','media_buyer'));

drop policy if exists wam_select on public.wa_messages;
create policy wam_select on public.wa_messages for select to authenticated using (true);
drop policy if exists wam_iud on public.wa_messages;
create policy wam_iud on public.wa_messages for all to authenticated using (public.my_role() in ('admin','confirmatrice','media_buyer')) with check (public.my_role() in ('admin','confirmatrice','media_buyer'));

drop policy if exists waf_select on public.wa_agent_flows;
create policy waf_select on public.wa_agent_flows for select to authenticated using (true);
drop policy if exists waf_iud on public.wa_agent_flows;
create policy waf_iud on public.wa_agent_flows for all to authenticated using (public.my_role()='admin') with check (public.my_role()='admin');

-- 7) Realtime
do $$ begin
  begin alter publication supabase_realtime add table public.wa_campaigns; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wa_campaign_recipients; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wa_conversations; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wa_messages; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wa_agent_flows; exception when others then null; end;
end $$;

-- 8) Seed: 5 flows par defaut (FR)
insert into public.wa_agent_flows (name,trigger_type,trigger_value,match_type,language,response_template,suggested_action,priority,active) values
 ('Confirmation positive','keyword','oui|d''accord|ok|confirme|nam|na3am|yes','regex','fr','Parfait {name} ! Votre commande de {product} ({price} DA) est confirmee. Le livreur passera dans 48-72h. Merci !','confirm_order',10,true),
 ('Refus','keyword','non|pas|refus|no|maranich|maandich','regex','fr','D''accord {name}, nous annulons la commande. Si vous changez d''avis, n''hesitez pas. Bonne journee.','mark_refused',9,true),
 ('Reporter','keyword','plus tard|demain|rappel|after|baada','regex','fr','Pas de probleme {name}, je vous rappelle plus tard. Quel moment vous convient ?','mark_reschedule',8,true),
 ('Question prix','keyword','prix|combien|tarif|cher|cost','regex','fr','Le prix total est de {price} DA avec livraison comprise. Paiement uniquement a la livraison ({wilaya}).','',7,true),
 ('Question livraison','keyword','livraison|quand|delai|when','regex','fr','La livraison prend 48-72h par {transporteur}. Le livreur vous appellera avant de passer.','',7,true)
on conflict do nothing;

-- 9) Vue: campagnes avec progress
-- drop + create : la vue fige la liste des colonnes de c.* ; un simple
-- "create or replace" échoue si une migration ultérieure ajoute une colonne.
drop view if exists public.wa_campaigns_with_progress;
create view public.wa_campaigns_with_progress as
select
  c.*,
  case when c.total_recipients>0 then round((c.sent_count::numeric/c.total_recipients)*100,1) else 0 end as progress_pct,
  c.total_recipients - c.sent_count - c.failed_count as remaining_count
from public.wa_campaigns c;

select 'Migration v8 OK' as status,
  (select count(*) from public.wa_agent_flows) as default_flows,
  (select count(*) from public.wa_campaigns) as campaigns;


-- =====================================================================
-- COD TEAM — Migration v9 (Baileys relay support)
-- A coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) Mode d'envoi sur les campagnes
alter table public.wa_campaigns add column if not exists send_mode text default 'manual' check (send_mode in ('manual','baileys'));
alter table public.wa_campaign_recipients add column if not exists last_error_at timestamptz;
alter table public.wa_campaign_recipients add column if not exists retry_count int default 0;

-- La vue v8 a été créée avant send_mode : on la reconstruit pour exposer
-- la nouvelle colonne (sinon la vue reste figée sur l'ancienne liste).
drop view if exists public.wa_campaigns_with_progress;
create view public.wa_campaigns_with_progress as
select
  c.*,
  case when c.total_recipients>0 then round((c.sent_count::numeric/c.total_recipients)*100,1) else 0 end as progress_pct,
  c.total_recipients - c.sent_count - c.failed_count as remaining_count
from public.wa_campaigns c;

-- 2) Statut du relais Baileys (1 ligne globale)
create table if not exists public.wa_relay_status (
  id text primary key default 'singleton' check (id='singleton'),
  connection_state text default 'disconnected' check (connection_state in ('disconnected','qr','connecting','connected','error')),
  qr_code text default '',
  phone_number text default '',
  last_heartbeat timestamptz default now(),
  daily_sent_count int default 0,
  daily_sent_reset_at timestamptz default now(),
  total_sent int default 0,
  total_failed int default 0,
  updated_at timestamptz default now()
);
insert into public.wa_relay_status (id) values ('singleton') on conflict do nothing;

alter table public.wa_relay_status enable row level security;
drop policy if exists wrs_select on public.wa_relay_status;
create policy wrs_select on public.wa_relay_status for select to authenticated using (true);
drop policy if exists wrs_iud on public.wa_relay_status;
create policy wrs_iud on public.wa_relay_status for all to authenticated using (true) with check (true);

-- 3) Realtime
do $$ begin
  begin alter publication supabase_realtime add table public.wa_relay_status; exception when others then null; end;
end $$;

-- 4) Conversations: lien optionnel vers ordre + AI flow declenche
alter table public.wa_conversations add column if not exists order_id uuid references public.orders(id) on delete set null;
alter table public.wa_messages add column if not exists matched_flow_id uuid references public.wa_agent_flows(id) on delete set null;
alter table public.wa_messages add column if not exists suggested_action text default '';

select 'Migration v9 OK' as status;


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


-- =====================================================================
-- COD TEAM — Migration v12 (Variable rémunération confirmatrices)
-- À coller dans Supabase Dashboard -> SQL Editor -> New query -> Run
-- =====================================================================

-- 1) Champs auxiliaires sur orders pour le calcul (idempotent)
alter table public.orders add column if not exists call_attempts int default 0;
alter table public.orders add column if not exists fake_reversed boolean default false;  -- admin marque qd "fake" mal qualifié

-- 2) Salaire de référence dans profiles (pour calculer 80/20)
alter table public.profiles add column if not exists base_salary_dzd numeric(10,2) default 0;
alter table public.profiles add column if not exists variable_pct numeric(5,2) default 20;

-- 3) Table des seuils (éditables par admin)
create table if not exists public.comp_thresholds (
  id uuid primary key default gen_random_uuid(),
  criterion text not null check (criterion in (
    'volume', 'fpy', 'delivery_rate', 'fake_quality', 'sla_punctuality'
  )),
  tier_order int not null,
  threshold_value numeric(10,2) not null,
  payout_pct int not null,
  label text default '',
  active boolean default true,
  created_at timestamptz default now(),
  unique (criterion, tier_order)
);

-- Seed par défaut (modèle 80% fixe + 20% variable, base 35 000 DA → 7 000 DA max)
insert into public.comp_thresholds (criterion, tier_order, threshold_value, payout_pct, label) values
  -- Critère 1 : Volume commandes confirmées (35% = 2450 DA max)
  ('volume', 1, 200, 50, '200-249 cmd : 50%'),
  ('volume', 2, 250, 75, '250-299 cmd : 75%'),
  ('volume', 3, 300, 100, '300-399 cmd : 100%'),
  ('volume', 4, 400, 150, '400+ cmd : 150% (stretch)'),
  -- Critère 2 : Taux confirmation 1er appel FPY (25% = 1750 DA max)
  ('fpy', 1, 50, 50, '50-59% FPY : 50%'),
  ('fpy', 2, 60, 75, '60-69% FPY : 75%'),
  ('fpy', 3, 70, 100, '70-79% FPY : 100%'),
  ('fpy', 4, 80, 150, '80%+ FPY : 150%'),
  -- Critère 3 : Taux livraison (20% = 1400 DA max)
  ('delivery_rate', 1, 60, 50, '60-69% livré : 50%'),
  ('delivery_rate', 2, 70, 75, '70-79% livré : 75%'),
  ('delivery_rate', 3, 80, 100, '80-89% livré : 100%'),
  ('delivery_rate', 4, 90, 150, '90%+ livré : 150%'),
  -- Critère 4 : Qualité fake (10% = 700 DA max) — INVERSÉ : moins d'erreurs = mieux
  ('fake_quality', 1, 0, 100, '0 erreur fake : 100%'),
  ('fake_quality', 2, 1, 70, '1 erreur fake : 70%'),
  ('fake_quality', 3, 2, 30, '2 erreurs fake : 30%'),
  ('fake_quality', 4, 3, 0, '3+ erreurs fake : 0%'),
  -- Critère 5 : Ponctualité SLA (10% = 700 DA max)
  ('sla_punctuality', 1, 70, 50, '70-79% dans SLA : 50%'),
  ('sla_punctuality', 2, 80, 75, '80-89% dans SLA : 75%'),
  ('sla_punctuality', 3, 90, 100, '90-94% dans SLA : 100%'),
  ('sla_punctuality', 4, 95, 120, '95%+ dans SLA : 120% (stretch)')
on conflict (criterion, tier_order) do nothing;

-- 4) Table des calculs mensuels
create table if not exists public.comp_runs (
  id uuid primary key default gen_random_uuid(),
  period_month date not null,   -- toujours le 1er du mois
  user_id uuid not null references public.profiles(id) on delete cascade,
  base_salary_dzd numeric(10,2) default 0,
  fixed_paid_dzd numeric(10,2) default 0,
  max_variable_dzd numeric(10,2) default 0,
  -- Critère 1 — Volume
  volume_count int default 0,
  volume_payout_pct int default 0,
  volume_payout_dzd numeric(10,2) default 0,
  volume_weight_pct int default 35,
  -- Critère 2 — FPY
  fpy_handled int default 0,
  fpy_success int default 0,
  fpy_rate numeric(5,2) default 0,
  fpy_payout_pct int default 0,
  fpy_payout_dzd numeric(10,2) default 0,
  fpy_weight_pct int default 25,
  -- Critère 3 — Delivery rate
  dr_confirmed int default 0,
  dr_delivered int default 0,
  dr_rate numeric(5,2) default 0,
  dr_payout_pct int default 0,
  dr_payout_dzd numeric(10,2) default 0,
  dr_weight_pct int default 20,
  -- Critère 4 — Fake quality
  fq_errors int default 0,
  fq_payout_pct int default 0,
  fq_payout_dzd numeric(10,2) default 0,
  fq_weight_pct int default 10,
  -- Critère 5 — SLA punctuality
  sla_eligible int default 0,
  sla_on_time int default 0,
  sla_rate numeric(5,2) default 0,
  sla_payout_pct int default 0,
  sla_payout_dzd numeric(10,2) default 0,
  sla_weight_pct int default 10,
  -- Total
  total_variable_dzd numeric(10,2) default 0,
  total_paid_dzd numeric(10,2) default 0,
  status text not null default 'draft' check (status in ('draft','computed','approved','paid','rejected')),
  computed_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  paid_at timestamptz,
  notes text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (period_month, user_id)
);
create index if not exists comp_runs_user_period_idx on public.comp_runs(user_id, period_month desc);
create index if not exists comp_runs_status_idx on public.comp_runs(status);

-- 5) RLS
alter table public.comp_thresholds enable row level security;
drop policy if exists ct_select on public.comp_thresholds;
create policy ct_select on public.comp_thresholds for select to authenticated using (true);
drop policy if exists ct_iud on public.comp_thresholds;
create policy ct_iud on public.comp_thresholds for all to authenticated
  using (public.my_role()='admin') with check (public.my_role()='admin');

alter table public.comp_runs enable row level security;
drop policy if exists cr_select on public.comp_runs;
create policy cr_select on public.comp_runs for select to authenticated
  using (user_id = auth.uid() or public.my_role()='admin');
drop policy if exists cr_iud on public.comp_runs;
create policy cr_iud on public.comp_runs for all to authenticated
  using (public.my_role()='admin') with check (public.my_role()='admin');

-- 6) Trigger updated_at
create or replace function public.touch_comp_runs() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists comp_runs_touch on public.comp_runs;
create trigger comp_runs_touch before update on public.comp_runs
  for each row execute function public.touch_comp_runs();

-- 7) Realtime
do $$ begin
  begin alter publication supabase_realtime add table public.comp_thresholds; exception when others then null; end;
  begin alter publication supabase_realtime add table public.comp_runs; exception when others then null; end;
end $$;

-- 8) Fonction de calcul mensuel (peut être appelée depuis JS via RPC ou par l'admin)
create or replace function public.compute_monthly_comp(p_user_id uuid, p_period date)
returns public.comp_runs language plpgsql security definer as $$
declare
  v_run public.comp_runs;
  v_month_start timestamptz;
  v_month_end timestamptz;
  v_profile public.profiles;
  v_base numeric(10,2);
  v_var_pct numeric(5,2);
  v_var_max numeric(10,2);

  v_volume int;
  v_fpy_handled int; v_fpy_success int; v_fpy_rate numeric(5,2);
  v_dr_confirmed int; v_dr_delivered int; v_dr_rate numeric(5,2);
  v_fq_errors int;
  v_sla_eligible int; v_sla_on_time int; v_sla_rate numeric(5,2);

  v_vol_pct int; v_fpy_pct int; v_dr_pct int; v_fq_pct int; v_sla_pct int;
  v_vol_max numeric(10,2); v_fpy_max numeric(10,2); v_dr_max numeric(10,2); v_fq_max numeric(10,2); v_sla_max numeric(10,2);
  v_vol_pay numeric(10,2); v_fpy_pay numeric(10,2); v_dr_pay numeric(10,2); v_fq_pay numeric(10,2); v_sla_pay numeric(10,2);
  v_total numeric(10,2);
begin
  v_month_start := date_trunc('month', p_period)::timestamptz;
  v_month_end := (date_trunc('month', p_period) + interval '1 month')::timestamptz;

  select * into v_profile from public.profiles where id = p_user_id;
  if v_profile is null then raise exception 'Profile not found'; end if;
  v_base := coalesce(v_profile.base_salary_dzd, 0);
  v_var_pct := coalesce(v_profile.variable_pct, 20);
  v_var_max := round(v_base * v_var_pct / 100, 2);

  -- Critère 1 : Volume (confirmed + delivered)
  select count(*) into v_volume from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and status in ('confirmed', 'delivered');

  -- Critère 2 : FPY (1er appel)
  select count(*) into v_fpy_handled from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and status in ('confirmed', 'delivered', 'refused', 'no_answer');
  select count(*) into v_fpy_success from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and status in ('confirmed', 'delivered')
     and coalesce(call_attempts, 1) <= 1;
  v_fpy_rate := case when v_fpy_handled > 0 then round((v_fpy_success::numeric / v_fpy_handled) * 100, 2) else 0 end;

  -- Critère 3 : Delivery rate (delivered/confirmed)
  v_dr_confirmed := v_volume;
  select count(*) into v_dr_delivered from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and status = 'delivered';
  v_dr_rate := case when v_dr_confirmed > 0 then round((v_dr_delivered::numeric / v_dr_confirmed) * 100, 2) else 0 end;

  -- Critère 4 : Fake quality (commandes marquées fake puis annulées par admin)
  select count(*) into v_fq_errors from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and fake_reversed = true;

  -- Critère 5 : SLA punctuality (% confirmations dans le délai SLA)
  select count(*) into v_sla_eligible from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and status in ('confirmed', 'delivered')
     and sla_deadline is not null;
  select count(*) into v_sla_on_time from public.orders
   where assignee_id = p_user_id
     and created_at >= v_month_start and created_at < v_month_end
     and status in ('confirmed', 'delivered')
     and sla_deadline is not null
     and last_call_at is not null
     and last_call_at <= sla_deadline;
  v_sla_rate := case when v_sla_eligible > 0 then round((v_sla_on_time::numeric / v_sla_eligible) * 100, 2) else 0 end;

  -- Appliquer les seuils (highest tier achieved wins)
  select coalesce(max(payout_pct), 0) into v_vol_pct from public.comp_thresholds
    where criterion = 'volume' and active = true and threshold_value <= v_volume;
  select coalesce(max(payout_pct), 0) into v_fpy_pct from public.comp_thresholds
    where criterion = 'fpy' and active = true and threshold_value <= v_fpy_rate;
  select coalesce(max(payout_pct), 0) into v_dr_pct from public.comp_thresholds
    where criterion = 'delivery_rate' and active = true and threshold_value <= v_dr_rate;
  -- Fake quality : INVERSÉ (moins d'erreurs = mieux). Trouver le tier dont threshold >= errors
  select coalesce(min(payout_pct), 0) into v_fq_pct from public.comp_thresholds
    where criterion = 'fake_quality' and active = true and threshold_value >= v_fq_errors;
  select coalesce(max(payout_pct), 0) into v_sla_pct from public.comp_thresholds
    where criterion = 'sla_punctuality' and active = true and threshold_value <= v_sla_rate;

  -- Calcul des montants par critère (poids fixes pour l'instant)
  v_vol_max := round(v_var_max * 35 / 100, 2);
  v_fpy_max := round(v_var_max * 25 / 100, 2);
  v_dr_max  := round(v_var_max * 20 / 100, 2);
  v_fq_max  := round(v_var_max * 10 / 100, 2);
  v_sla_max := round(v_var_max * 10 / 100, 2);

  v_vol_pay := round(v_vol_max * v_vol_pct / 100, 2);
  v_fpy_pay := round(v_fpy_max * v_fpy_pct / 100, 2);
  v_dr_pay  := round(v_dr_max  * v_dr_pct  / 100, 2);
  v_fq_pay  := round(v_fq_max  * v_fq_pct  / 100, 2);
  v_sla_pay := round(v_sla_max * v_sla_pct / 100, 2);

  v_total := v_vol_pay + v_fpy_pay + v_dr_pay + v_fq_pay + v_sla_pay;
  -- Cap absolu à 150% du variable max (anti-glitch)
  v_total := least(v_total, v_var_max * 1.5);

  -- Insérer ou mettre à jour
  insert into public.comp_runs (
    period_month, user_id, base_salary_dzd, fixed_paid_dzd, max_variable_dzd,
    volume_count, volume_payout_pct, volume_payout_dzd,
    fpy_handled, fpy_success, fpy_rate, fpy_payout_pct, fpy_payout_dzd,
    dr_confirmed, dr_delivered, dr_rate, dr_payout_pct, dr_payout_dzd,
    fq_errors, fq_payout_pct, fq_payout_dzd,
    sla_eligible, sla_on_time, sla_rate, sla_payout_pct, sla_payout_dzd,
    total_variable_dzd, total_paid_dzd, status, computed_at
  ) values (
    date_trunc('month', p_period)::date, p_user_id, v_base, round(v_base * (100 - v_var_pct) / 100, 2), v_var_max,
    v_volume, v_vol_pct, v_vol_pay,
    v_fpy_handled, v_fpy_success, v_fpy_rate, v_fpy_pct, v_fpy_pay,
    v_dr_confirmed, v_dr_delivered, v_dr_rate, v_dr_pct, v_dr_pay,
    v_fq_errors, v_fq_pct, v_fq_pay,
    v_sla_eligible, v_sla_on_time, v_sla_rate, v_sla_pct, v_sla_pay,
    v_total, round(v_base * (100 - v_var_pct) / 100, 2) + v_total, 'computed', now()
  )
  on conflict (period_month, user_id) do update set
    base_salary_dzd = excluded.base_salary_dzd,
    fixed_paid_dzd = excluded.fixed_paid_dzd,
    max_variable_dzd = excluded.max_variable_dzd,
    volume_count = excluded.volume_count,
    volume_payout_pct = excluded.volume_payout_pct,
    volume_payout_dzd = excluded.volume_payout_dzd,
    fpy_handled = excluded.fpy_handled,
    fpy_success = excluded.fpy_success,
    fpy_rate = excluded.fpy_rate,
    fpy_payout_pct = excluded.fpy_payout_pct,
    fpy_payout_dzd = excluded.fpy_payout_dzd,
    dr_confirmed = excluded.dr_confirmed,
    dr_delivered = excluded.dr_delivered,
    dr_rate = excluded.dr_rate,
    dr_payout_pct = excluded.dr_payout_pct,
    dr_payout_dzd = excluded.dr_payout_dzd,
    fq_errors = excluded.fq_errors,
    fq_payout_pct = excluded.fq_payout_pct,
    fq_payout_dzd = excluded.fq_payout_dzd,
    sla_eligible = excluded.sla_eligible,
    sla_on_time = excluded.sla_on_time,
    sla_rate = excluded.sla_rate,
    sla_payout_pct = excluded.sla_payout_pct,
    sla_payout_dzd = excluded.sla_payout_dzd,
    total_variable_dzd = excluded.total_variable_dzd,
    total_paid_dzd = excluded.total_paid_dzd,
    status = case when comp_runs.status = 'paid' then 'paid' else 'computed' end,
    computed_at = excluded.computed_at,
    updated_at = now()
  returning * into v_run;

  return v_run;
end; $$;

-- 9) Auto-incrément call_attempts (à chaque setOrderStatus = calling)
create or replace function public.bump_call_attempts() returns trigger
language plpgsql as $$
begin
  if new.status = 'calling' and (old.status is null or old.status != 'calling') then
    new.call_attempts := coalesce(new.call_attempts, 0) + 1;
  end if;
  return new;
end; $$;
drop trigger if exists bump_call_attempts_trg on public.orders;
create trigger bump_call_attempts_trg before update on public.orders
  for each row execute function public.bump_call_attempts();

select 'Migration v12 OK' as status,
  (select count(*) from public.comp_thresholds) as thresholds_seeded;

-- #####################################################################
-- #  VÉRIFICATION FINALE
-- #####################################################################
-- Doit retourner 28 tables, 58 wilayas, 10 réglages.
select 'Bootstrap complet OK' as status,
       (select count(*) from information_schema.tables
         where table_schema = 'public' and table_type = 'BASE TABLE') as tables,
       (select count(*) from public.wilayas)  as wilayas,
       (select count(*) from public.settings) as settings;
