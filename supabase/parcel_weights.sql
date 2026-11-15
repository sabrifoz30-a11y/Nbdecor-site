-- weight of each parcel (kg); weight_kg keeps the total
alter table public.orders add column if not exists parcel_weights jsonb;
drop function if exists public.pack_order(bigint, int, numeric);
create or replace function public.pack_order(oid bigint, n int, kg numeric default null, kgs jsonb default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; nm text; w jsonb; tot numeric;
begin
  if public.my_role() not in ('packer','owner') then raise exception 'not allowed'; end if;
  if n is null or n < 1 or n > 50 then raise exception 'bad parcels'; end if;
  select * into o from public.orders where id = oid and store_id = public.my_store() for update;
  if not found then raise exception 'no order'; end if;
  if o.status <> 'ready' then raise exception 'not ready'; end if;
  if kgs is not null and jsonb_typeof(kgs) = 'array' then
    select jsonb_agg(case when (x #>> '{}') ~ '^[0-9]+(\.[0-9]+)?$' and (x #>> '{}')::numeric > 0 then to_jsonb(round((x #>> '{}')::numeric, 2)) else 'null'::jsonb end order by i)
      into w from jsonb_array_elements(kgs) with ordinality t(x, i) where i <= n;
    select sum((x #>> '{}')::numeric) into tot from jsonb_array_elements(w) x where jsonb_typeof(x) = 'number';
  end if;
  select name into nm from public.profiles where id = auth.uid();
  update public.orders set parcel_count = n, parcel_weights = w,
    weight_kg = coalesce(tot, case when kg is null or kg <= 0 then null else kg end),
    packed_at = now(), packed_by = auth.uid(), updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'packed', 'by', nm, 'parcels', n, 'kg', coalesce(tot, kg), 'kgs', w))
  where id = oid returning * into o;
  return to_jsonb(o);
end $$;
revoke all on function public.pack_order(bigint, int, numeric, jsonb) from public, anon;
grant execute on function public.pack_order(bigint, int, numeric, jsonb) to authenticated;
CREATE OR REPLACE FUNCTION public.carrier_ship(oid bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st text := public.my_store(); o public.orders; sh jsonb; comp jsonb; tok text; base text; cu jsonb; ph text; w int; body jsonb; rid bigint; rem text; prod text;
begin
  if public.my_role() not in ('packer','owner') then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = oid and store_id = st for update;
  if not found then raise exception 'no order'; end if;
  if o.status <> 'ready' or o.packed_at is null then raise exception 'not packed'; end if;
  if o.carrier_tracking is not null then raise exception 'already shipped'; end if;
  select data->'shipping' into sh from public.settings where store_id = st;
  select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c where c->>'id' = sh->>'def';
  if comp is null then raise exception 'no default company'; end if;
  if coalesce(comp->>'platform','ecotrack') not in ('ecotrack','dhd') then raise exception 'platform not supported yet'; end if;
  select value into tok from public.secrets where store_id = st and key = 'carrier:'||(comp->>'id');
  if tok is null then raise exception 'no token'; end if;
  base := rtrim(coalesce(comp->>'base',''),'/');
  if base !~ '^https://[a-z0-9.-]+$' then raise exception 'bad base url'; end if;
  cu := o.customer;
  ph := public.dz_phone(cu->>'phone'); if ph is null then raise exception 'bad phone'; end if;
  w := coalesce(nullif(cu->>'wilaya_no','')::int, nullif(split_part(coalesce(cu->>'wilaya',''),' ',1),'')::int);
  if coalesce(cu->>'commune','') = '' then raise exception 'no commune'; end if;
  rem := left(concat_ws(' · ', o.parcel_count||' طرد', case when o.parcel_weights is not null and jsonb_array_length(o.parcel_weights) > 1 then (select string_agg('طرد '||i||': '||(x #>> '{}')||' كغ', '، ' order by i) from jsonb_array_elements(o.parcel_weights) with ordinality t(x,i) where jsonb_typeof(x)='number') when o.weight_kg is not null then o.weight_kg||' كغ' end, nullif(trim(coalesce(cu->>'notes','')),'')), 255);
  prod := left((select string_agg(coalesce(i->>'ref','')||' x'||coalesce(i->>'qty','1'), ', ') from jsonb_array_elements(o.items) i), 255);
  body := jsonb_strip_nulls(jsonb_build_object(
    'reference', '#'||o.id, 'nom_client', left(coalesce(cu->>'name',''),255), 'telephone', ph,
    'adresse', left(coalesce(nullif(trim(cu->>'address'),''), cu->>'commune'),255), 'commune', cu->>'commune', 'code_wilaya', w,
    'montant', coalesce(o.total,0) + coalesce(o.shipping,0), 'remarque', rem, 'produit', prod,
    'type', 1, 'stop_desk', case when cu->>'delivery' = 'مكتب' then 1 else 0 end, 'stock', 0));
  select net.http_post(url := base||'/api/v1/create/order', body := body,
    headers := jsonb_build_object('Authorization','Bearer '||tok,'Content-Type','application/json','Accept','application/json'), timeout_milliseconds := 30000) into rid;
  insert into public.carrier_requests(rid, store_id) values (rid, st);
  update public.orders set carrier_req = rid, carrier_name = comp->>'name' where id = oid;
  return rid;
end $function$
;