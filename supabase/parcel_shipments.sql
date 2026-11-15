-- One carrier shipment per parcel: each parcel gets its own reference (#ID-1/3), its own weight (field "weight", kg rounded up),
-- the customer info and the products. The cash-on-delivery amount goes on parcel 1 only.
alter table public.orders add column if not exists carrier_parcels jsonb;

create or replace function public.carrier_ship(oid bigint) returns bigint language plpgsql security definer set search_path = public as $$
declare st text := public.my_store(); o public.orders; sh jsonb; comp jsonb; tok text; base text; cu jsonb; ph text; w int; body jsonb; rid bigint;
  prod text; n int; i int; kg numeric; cp jsonb; it jsonb; last bigint;
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
  n := greatest(coalesce(o.parcel_count,1),1);
  -- every parcel needs its weight
  for i in 1..n loop
    kg := case when o.parcel_weights is not null and jsonb_typeof(o.parcel_weights->(i-1)) = 'number' then (o.parcel_weights->>(i-1))::numeric
               when n = 1 then o.weight_kg end;
    if kg is null or kg <= 0 then raise exception 'missing weight'; end if;
  end loop;
  -- keep parcels already accepted by the carrier (retry only the others)
  cp := coalesce(o.carrier_parcels, '[]'::jsonb);
  if jsonb_array_length(cp) <> n and exists (select 1 from jsonb_array_elements(cp) x where x ? 'tracking') then raise exception 'repacked after partial ship'; end if;
  if jsonb_array_length(cp) <> n then cp := '[]'::jsonb; for i in 1..n loop cp := cp || jsonb_build_array(jsonb_build_object('i', i)); end loop; end if;
  prod := (select string_agg(coalesce(x->>'ref','')||' x'||coalesce(x->>'qty','1'), ', ') from jsonb_array_elements(o.items) x);
  for i in 1..n loop
    it := cp->(i-1);
    if it ? 'tracking' then continue; end if;
    kg := case when o.parcel_weights is not null and jsonb_typeof(o.parcel_weights->(i-1)) = 'number' then (o.parcel_weights->>(i-1))::numeric else o.weight_kg end;
    body := jsonb_strip_nulls(jsonb_build_object(
      'reference', case when n = 1 then '#'||o.id else '#'||o.id||'-'||i||'/'||n end,
      'nom_client', left(coalesce(cu->>'name',''),255), 'telephone', ph,
      'adresse', left(coalesce(nullif(trim(cu->>'address'),''), cu->>'commune'),255), 'commune', cu->>'commune', 'code_wilaya', w,
      'montant', case when i = 1 then coalesce(o.total,0) + coalesce(o.shipping,0) else 0 end,
      'weight', ceil(kg)::int,
      'remarque', left(concat_ws(' · ', case when n > 1 then 'طرد '||i||' من '||n end, 'الوزن '||kg||' كغ',
                   case when n > 1 and i > 1 then 'المبلغ كله مع الطرد 1' end, nullif(trim(coalesce(cu->>'notes','')),'')), 255),
      'produit', left(case when n > 1 then '(طرد '||i||'/'||n||') ' else '' end || coalesce(prod,''), 255),
      'type', 1, 'stop_desk', case when cu->>'delivery' = 'مكتب' then 1 else 0 end, 'stock', 0));
    select net.http_post(url := base||'/api/v1/create/order', body := body,
      headers := jsonb_build_object('Authorization','Bearer '||tok,'Content-Type','application/json','Accept','application/json'), timeout_milliseconds := 30000) into rid;
    insert into public.carrier_requests(rid, store_id) values (rid, st);
    cp := jsonb_set(cp, array[(i-1)::text], jsonb_build_object('i', i, 'kg', kg, 'rid', rid));
    last := rid;
  end loop;
  update public.orders set carrier_parcels = cp, carrier_req = coalesce(last, carrier_req), carrier_name = comp->>'name' where id = oid;
  return last;
end $$;

create or replace function public.carrier_ship_check(oid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; r record; j jsonb; trk text; nm text; cp jsonb; it jsonb; i int; pending int := 0; bad jsonb := '[]'::jsonb; trks text;
begin
  if public.my_role() not in ('packer','owner','confirmer') then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = oid and store_id = public.my_store() for update;
  if not found then raise exception 'no order'; end if;
  if o.carrier_tracking is not null then return jsonb_build_object('done', true, 'ok', true, 'tracking', o.carrier_tracking, 'parcels', o.carrier_parcels); end if;
  cp := o.carrier_parcels;
  if cp is null or jsonb_array_length(cp) = 0 then return jsonb_build_object('done', false); end if;
  for i in 0..jsonb_array_length(cp)-1 loop
    it := cp->i;
    if it ? 'tracking' or not (it ? 'rid') then continue; end if;
    select status_code, content, error_msg into r from net._http_response where id = (it->>'rid')::bigint;
    if not found then pending := pending + 1; continue; end if;
    begin j := r.content::jsonb; exception when others then j := null; end;
    trk := coalesce(j->>'tracking', j->'data'->>'tracking', j->>'tracking_id', j->'order'->>'tracking');
    if r.status_code between 200 and 299 and coalesce(j->>'success','true') <> 'false' and trk is not null then
      cp := jsonb_set(cp, array[i::text], (it - 'rid') || jsonb_build_object('tracking', trk));
    else
      cp := jsonb_set(cp, array[i::text], it - 'rid');  -- allow a retry of this parcel
      bad := bad || jsonb_build_array(jsonb_build_object('i', it->'i', 'status', r.status_code, 'body', left(coalesce(r.content, r.error_msg, ''), 400)));
    end if;
  end loop;
  update public.orders set carrier_parcels = cp where id = oid;
  if pending > 0 then return jsonb_build_object('done', false, 'parcels', cp); end if;
  if jsonb_array_length(bad) = 0 and not exists (select 1 from jsonb_array_elements(cp) x where not (x ? 'tracking')) then
    select string_agg(x->>'tracking', ' ، ' order by (x->>'i')::int) into trks from jsonb_array_elements(cp) x;
    select name into nm from public.profiles where id = auth.uid();
    update public.orders set carrier_tracking = trks, tracking = coalesce(tracking, trks), carrier_at = now(), carrier_req = null, updated_at = now(),
      history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'carrier', 'by', nm, 'company', o.carrier_name, 'tracking', trks))
    where id = oid;
    return jsonb_build_object('done', true, 'ok', true, 'tracking', trks, 'parcels', cp);
  end if;
  update public.orders set carrier_req = null where id = oid;
  return jsonb_build_object('done', true, 'ok', false, 'parcels', cp, 'failed', bad,
    'status', bad->0->'status', 'body', bad->0->>'body');
end $$;
revoke all on function public.carrier_ship(bigint) from public, anon;
revoke all on function public.carrier_ship_check(bigint) from public, anon;
grant execute on function public.carrier_ship(bigint) to authenticated;
grant execute on function public.carrier_ship_check(bigint) to authenticated;
