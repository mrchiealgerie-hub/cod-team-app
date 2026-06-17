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
