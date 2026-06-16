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
