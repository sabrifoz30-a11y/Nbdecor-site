-- Arabic commune names (from the open dataset @dzcode-io/leblad), matched by postal code, else by name
create table if not exists public.commune_names (code text, norm text, wil int, name_ar text not null);
create index if not exists commune_names_code on public.commune_names(code);
create index if not exists commune_names_norm on public.commune_names(norm);
alter table public.commune_names enable row level security;
drop policy if exists "read commune names" on public.commune_names;
create policy "read commune names" on public.commune_names for select using (true);
alter table public.communes add column if not exists name_ar text;

create or replace function public.com_norm(t text) returns text language sql immutable as $$
  select regexp_replace(lower(translate(coalesce(t,''),'éèêëàâäîïôöûüçÉÈÊËÀÂÄÎÏÔÖÛÜÇ','eeeeaaaiioouucEEEEAAAIIOOUUC')),'[^a-z]','','g') $$;
create or replace function public.com_ar(p_postal text, p_name text, p_wil int) returns text language sql stable as $$
  select coalesce(
    (select name_ar from public.commune_names where code = p_postal limit 1),
    (select name_ar from public.commune_names where norm = public.com_norm(p_name) order by (wil = p_wil) desc limit 1)) $$;
create or replace function public.communes_ar() returns trigger language plpgsql as $$
begin new.name_ar := coalesce(new.name_ar, public.com_ar(new.postal, new.name, new.wilaya)); return new; end $$;
drop trigger if exists communes_ar on public.communes;
create trigger communes_ar before insert or update of name, postal on public.communes for each row execute function public.communes_ar();
-- names missing from the dataset
insert into public.commune_names(code,norm,wil,name_ar) values
 ('3208',public.com_norm('Ain El Orak'),32,'عين العراك'),('3213',public.com_norm('Boussemghoun'),32,'بوسمغون'),
 ('3207',public.com_norm('El Biodh Sidi Cheikh'),32,'البيض سيدي الشيخ'),('3220',public.com_norm('Tousmouline'),32,'توسمولين'),
 ('5202',public.com_norm('Ouled Khoudir'),52,'أولاد خضير'),('5303',public.com_norm('Foggaret Azzaouia'),53,'فقارة الزوى'),
 ('5301',public.com_norm('In Salah'),53,'عين صالح'),('5401',public.com_norm('In Guezzam'),54,'عين قزام'),
 ('5602',public.com_norm('Bordj El Haouasse'),56,'برج الحواس'),('5701',public.com_norm('El M''ghair'),57,'المغير');
