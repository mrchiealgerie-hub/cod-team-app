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
