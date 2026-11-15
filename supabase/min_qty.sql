-- minimum order quantity on the server (settings.minQty, default 10 pieces; a carton line counts qty * carton pieces)
CREATE OR REPLACE FUNCTION public.place_order(customer jsonb, items jsonb, store text DEFAULT 'nbdecor'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare oid bigint; tot int := 0; it jsonb; sf jsonb; pcs int := 0; mq int;
begin
  if not exists (select 1 from public.stores where id = store and status <> 'suspended') then raise exception 'unknown store'; end if;
  if coalesce(trim(customer->>'name'),'') = '' then raise exception 'missing customer info'; end if;
  if public.dz_phone(customer->>'phone') is null then raise exception 'bad phone'; end if;
  customer := customer || jsonb_build_object('phone', public.dz_phone(customer->>'phone'));
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    tot := tot + greatest(0, coalesce((it->>'price')::int,0)) * greatest(1, coalesce((it->>'qty')::int,1));
  end loop;
  select coalesce(nullif(data->>'minQty','')::int, 10) into mq from public.settings where store_id = store;
  select coalesce(sum(greatest(1, coalesce((i->>'qty')::int,1)) * greatest(1, coalesce((i->>'carton')::int,1))),0) into pcs from jsonb_array_elements(items) i;
  if pcs < coalesce(mq,10) then raise exception 'min quantity'; end if;
  sf := public.ship_fee(customer, store);
  insert into public.orders(store_id, customer, items, total, shipping, shipping_company, history)
  values (store, customer, items, tot, coalesce((sf->>'fee')::int,0), sf->>'company', jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')))
  returning id into oid;
  return oid;
end $function$
;