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
