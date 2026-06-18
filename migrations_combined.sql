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
create or replace view public.wa_campaigns_with_progress as
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
