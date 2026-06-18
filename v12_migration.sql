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
