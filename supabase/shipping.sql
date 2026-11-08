-- shipping: fee computed on the server from settings.shipping (default company, per-wilaya rates)
alter table public.orders add column if not exists shipping_company text;

create or replace function public.ship_fee(customer jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sh jsonb; comp jsonb; r jsonb; w text; v text;
begin
  select data->'shipping' into sh from public.settings where id = 1;
  if sh is null then return jsonb_build_object('fee', null); end if;
  select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c where c->>'id' = coalesce(sh->>'def','') limit 1;
  if comp is null then select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c limit 1; end if;
  if comp is null then return jsonb_build_object('fee', null); end if;
  w := coalesce(nullif(customer->>'wilaya_no',''), split_part(coalesce(customer->>'wilaya',''),' ',1));
  r := comp->'rates'->(ltrim(w,'0'));
  v := case when customer->>'delivery' = 'مكتب' then r->>'d' else r->>'h' end;
  return jsonb_build_object('company', comp->>'name', 'fee', case when v ~ '^\d+$' then v::int end, 'off', coalesce((r->>'off')::boolean,false));
end $$;

create or replace function public.place_order(customer jsonb, items jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare oid bigint; tot int := 0; it jsonb; sf jsonb;
begin
  if coalesce(trim(customer->>'name'),'') = '' or length(regexp_replace(coalesce(customer->>'phone',''),'\D','','g')) < 9 then raise exception 'missing customer info'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    tot := tot + greatest(0, coalesce((it->>'price')::int,0)) * greatest(1, coalesce((it->>'qty')::int,1));
  end loop;
  sf := public.ship_fee(customer);
  insert into public.orders(customer, items, total, shipping, shipping_company, history)
  values (customer, items, tot, coalesce((sf->>'fee')::int,0), sf->>'company', jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')))
  returning id into oid;
  return oid;
end $$;
grant execute on function public.place_order(jsonb, jsonb) to anon, authenticated;
