-- Create the shipment at the default delivery company (Ecotrack platforms: Ecotrack/DHD) from the packing step.
alter table public.orders add column if not exists carrier_req bigint, add column if not exists carrier_tracking text,
  add column if not exists carrier_name text, add column if not exists carrier_at timestamptz;

create or replace function public.carrier_ship(oid bigint) returns bigint language plpgsql security definer set search_path = public as $$
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
  ph := regexp_replace(coalesce(cu->>'phone',''),'\D','','g'); if left(ph,3) = '213' then ph := '0'||substr(ph,4); end if; if length(ph) = 9 then ph := '0'||ph; end if;
  w := coalesce(nullif(cu->>'wilaya_no','')::int, nullif(split_part(coalesce(cu->>'wilaya',''),' ',1),'')::int);
  if coalesce(cu->>'commune','') = '' then raise exception 'no commune'; end if;
  rem := left(concat_ws(' · ', o.parcel_count||' طرد', case when o.weight_kg is not null then o.weight_kg||' كغ' end, nullif(trim(coalesce(cu->>'notes','')),'')), 255);
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
end $$;

create or replace function public.carrier_ship_check(oid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; r record; j jsonb; trk text; nm text;
begin
  if public.my_role() not in ('packer','owner','confirmer') then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = oid and store_id = public.my_store();
  if not found then raise exception 'no order'; end if;
  if o.carrier_tracking is not null then return jsonb_build_object('done', true, 'ok', true, 'tracking', o.carrier_tracking); end if;
  if o.carrier_req is null then return jsonb_build_object('done', false); end if;
  select status_code, content, error_msg, timed_out into r from net._http_response where id = o.carrier_req;
  if not found then return jsonb_build_object('done', false); end if;
  begin j := r.content::jsonb; exception when others then j := null; end;
  trk := coalesce(j->>'tracking', j->'data'->>'tracking', j->>'tracking_id', j->'order'->>'tracking');
  if r.status_code between 200 and 299 and coalesce(j->>'success','true') <> 'false' and trk is not null then
    select name into nm from public.profiles where id = auth.uid();
    update public.orders set carrier_tracking = trk, tracking = coalesce(tracking, trk), carrier_at = now(), updated_at = now(),
      history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'carrier', 'by', nm, 'company', o.carrier_name, 'tracking', trk))
    where id = oid;
    return jsonb_build_object('done', true, 'ok', true, 'tracking', trk);
  end if;
  update public.orders set carrier_req = null where id = oid;  -- allow a retry
  return jsonb_build_object('done', true, 'ok', false, 'status', r.status_code, 'error', coalesce(r.error_msg, ''), 'body', left(coalesce(r.content,''), 600));
end $$;
revoke all on function public.carrier_ship(bigint) from public, anon;
revoke all on function public.carrier_ship_check(bigint) from public, anon;
grant execute on function public.carrier_ship(bigint) to authenticated;
grant execute on function public.carrier_ship_check(bigint) to authenticated;
