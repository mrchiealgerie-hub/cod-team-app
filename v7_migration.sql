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
