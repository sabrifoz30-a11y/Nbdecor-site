-- Algerian phone numbers: mobile 0[567]XXXXXXXX (10 digits) or landline 0[2-4]XXXXXXX (9 digits)
create or replace function public.dz_phone(p text) returns text language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p,''),'\D','','g');
begin
  if left(d,5) = '00213' then d := substr(d,6); elsif left(d,3) = '213' then d := substr(d,4); end if;
  if left(d,1) <> '0' then d := '0'||d; end if;
  if d ~ '^0[567][0-9]{8}$' or d ~ '^0[2-4][0-9]{7}$' then return d; end if;
  return null;
end $$;

-- the packer/confirmer can correct a wrong phone number before shipping
create or replace function public.fix_order_phone(oid bigint, ph text) returns text language plpgsql security definer set search_path = public as $$
declare d text := public.dz_phone(ph); nm text;
begin
  if public.my_role() not in ('owner','confirmer','packer') then raise exception 'not allowed'; end if;
  if d is null then raise exception 'bad phone'; end if;
  select name into nm from public.profiles where id = auth.uid();
  update public.orders set customer = customer || jsonb_build_object('phone', d), updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'phone_fixed', 'by', nm, 'old', customer->>'phone', 'new', d))
  where id = oid and store_id = public.my_store();
  if not found then raise exception 'no order'; end if;
  return d;
end $$;
revoke all on function public.fix_order_phone(bigint, text) from public, anon;
grant execute on function public.fix_order_phone(bigint, text) to authenticated;
CREATE OR REPLACE FUNCTION public.place_order(customer jsonb, items jsonb, store text DEFAULT 'nbdecor'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare oid bigint; tot int := 0; it jsonb; sf jsonb;
begin
  if not exists (select 1 from public.stores where id = store and status <> 'suspended') then raise exception 'unknown store'; end if;
  if coalesce(trim(customer->>'name'),'') = '' then raise exception 'missing customer info'; end if;
  if public.dz_phone(customer->>'phone') is null then raise exception 'bad phone'; end if;
  customer := customer || jsonb_build_object('phone', public.dz_phone(customer->>'phone'));
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    tot := tot + greatest(0, coalesce((it->>'price')::int,0)) * greatest(1, coalesce((it->>'qty')::int,1));
  end loop;
  sf := public.ship_fee(customer, store);
  insert into public.orders(store_id, customer, items, total, shipping, shipping_company, history)
  values (store, customer, items, tot, coalesce((sf->>'fee')::int,0), sf->>'company', jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')))
  returning id into oid;
  return oid;
end $function$
;