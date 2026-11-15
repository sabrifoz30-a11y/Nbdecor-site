-- Before the first ad: (1) the server sets every item's price from the product itself, never from the browser;
-- (2) hidden products are not readable by the public; (3) no order to a wilaya the delivery company does not serve.

-- price of one order line, same rules as the shop (linePrice / priceFull)
create or replace function public.item_price(p jsonb, it jsonb) returns numeric language plpgsql immutable as $$
declare c jsonb := p->'carton'; best numeric := 0; v numeric; d jsonb; i int := 0; o text;
begin
  if coalesce((it->>'carton')::numeric,0) > 1 then
    if c is not null and coalesce((c->>'qty')::numeric,0) > 1 and coalesce((c->>'price')::numeric,0) > 0 then return (c->>'price')::numeric; end if;
    return null;  -- carton asked but the product has no carton price
  end if;
  if not coalesce((p->>'novar')::boolean,false) then
    if coalesce(it->>'color','') <> '' and jsonb_typeof(p->'vprices') = 'object' then
      v := case when (p->'vprices'->>(it->>'color')) ~ '^[0-9.]+$' then (p->'vprices'->>(it->>'color'))::numeric else 0 end;
      if v > best then best := v; end if;
    end if;
    if jsonb_typeof(p->'xv') = 'array' then
      for d in select * from jsonb_array_elements(p->'xv') loop
        o := it->'x'->>(i::text);
        if coalesce(o,'') <> '' and jsonb_typeof(d->'pr') = 'object' and (d->'pr'->>o) ~ '^[0-9.]+$' then
          v := (d->'pr'->>o)::numeric; if v > best then best := v; end if;
        end if;
        i := i + 1;
      end loop;
    end if;
  end if;
  if best > 0 then return best; end if;
  return nullif(coalesce((p->>'price')::numeric,0),0);
end $$;

create or replace function public.place_order(customer jsonb, items jsonb, store text default 'nbdecor') returns bigint language plpgsql security definer set search_path = public as $$
declare oid bigint; tot numeric := 0; it jsonb; sf jsonb; pcs int := 0; mq int; p jsonb; pr numeric; q int; fixed jsonb := '[]'::jsonb; ct int; sh jsonb; comp jsonb;
begin
  if not exists (select 1 from public.stores where id = store and status <> 'suspended') then raise exception 'unknown store'; end if;
  if coalesce(trim(customer->>'name'),'') = '' then raise exception 'missing customer info'; end if;
  if public.dz_phone(customer->>'phone') is null then raise exception 'bad phone'; end if;
  customer := customer || jsonb_build_object('phone', public.dz_phone(customer->>'phone'));
  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    select data into p from public.products where id = it->>'id' and store_id = store;
    if p is null or coalesce(p->>'hidden','false') = 'true' then raise exception 'unknown product %', coalesce(it->>'ref',''); end if;
    q := case when (it->>'qty') ~ '^[0-9]+$' then (it->>'qty')::int else 0 end;
    if q < 1 or q > 100000 then raise exception 'bad qty'; end if;
    pr := public.item_price(p, it);
    if pr is null or pr <= 0 then raise exception 'no price %', coalesce(it->>'ref',''); end if;
    ct := case when coalesce((it->>'carton')::numeric,0) > 1 then (p->'carton'->>'qty')::int end;
    fixed := fixed || jsonb_build_array(it || jsonb_build_object('qty', q, 'price', pr, 'ref', p->>'ref') || case when ct is not null then jsonb_build_object('carton', ct) else '{}'::jsonb end);
    tot := tot + pr * q;
    pcs := pcs + q * coalesce(ct, 1);
  end loop;
  select coalesce(nullif(data->>'minQty','')::int, 10), data->'shipping' into mq, sh from public.settings where store_id = store;
  if pcs < coalesce(mq,10) then raise exception 'min quantity'; end if;
  -- the default delivery company must serve this wilaya (when it has a price list)
  select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c where c->>'id' = coalesce(sh->>'def','') limit 1;
  if comp is null then select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c limit 1; end if;
  sf := public.ship_fee(customer, store);
  if jsonb_typeof(comp->'rates') = 'object' and comp->'rates' <> '{}'::jsonb and (sf->>'fee' is null or coalesce((sf->>'off')::boolean,false)) then
    raise exception 'no delivery';
  end if;
  insert into public.orders(store_id, customer, items, total, shipping, shipping_company, history)
  values (store, customer, fixed, tot, coalesce((sf->>'fee')::int,0), sf->>'company', jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')))
  returning id into oid;
  return oid;
end $$;

-- hidden products: only the store's staff can read them
drop policy if exists "read products" on public.products;
create policy "read products" on public.products for select using (
  coalesce(data->>'hidden','false') <> 'true' or (store_id = public.my_store() and public.my_role() <> 'anon'));
