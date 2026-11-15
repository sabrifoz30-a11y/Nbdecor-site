-- Anti-fraud (medium level): one order per phone within N hours (repeats are noted on the first order),
-- bot signs (hidden field, too-fast form), many phones from one device/internet, blacklist and odd names.
-- Nothing is rejected: suspicious orders get flags that the confirmer sees.
alter table public.orders add column if not exists flags jsonb, add column if not exists ip text, add column if not exists dev text;
create index if not exists orders_dev_idx on public.orders(store_id, dev, created_at);
create index if not exists orders_ip_idx on public.orders(store_id, ip, created_at);
create or replace function public.place_order(customer jsonb, items jsonb, store text default 'nbdecor') returns bigint language plpgsql security definer set search_path = public as $$
declare oid bigint; tot numeric := 0; fr jsonb; fl jsonb := '[]'::jsonb; v_ip text; v_dev text; ph text; hp text; ft numeric; prev public.orders; dh int; n int; nm text; it jsonb; sf jsonb; pcs int := 0; mq int; p jsonb; pr numeric; q int; fixed jsonb := '[]'::jsonb; ct int; sh jsonb; comp jsonb;
begin
  if not exists (select 1 from public.stores where id = store and status <> 'suspended') then raise exception 'unknown store'; end if;
  if coalesce(trim(customer->>'name'),'') = '' then raise exception 'missing customer info'; end if;
  if public.dz_phone(customer->>'phone') is null then raise exception 'bad phone'; end if;
  ph := public.dz_phone(customer->>'phone');
  customer := customer || jsonb_build_object('phone', ph);
  hp := nullif(trim(coalesce(customer->>'_hp','')),''); ft := case when (customer->>'_ft') ~ '^[0-9]+(\.[0-9]+)?$' then (customer->>'_ft')::numeric end;
  v_dev := case when (customer->>'_dev') ~ '^[a-z0-9]{8,40}$' then customer->>'_dev' end;
  customer := customer - '_hp' - '_ft' - '_dev';
  begin v_ip := split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1); exception when others then v_ip := null; end;
  v_ip := nullif(trim(v_ip),'');
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
  select coalesce(data->'fraud','{}'::jsonb) into fr from public.settings where store_id = store;
  dh := coalesce(nullif(fr->>'dupHours','')::int, 24);
  -- 1) same phone again within the window: keep one order (no duplicate), note the new request on it
  if dh > 0 then
    select * into prev from public.orders o where o.store_id = store and public.dz_phone(o.customer->>'phone') = ph and o.status <> 'cancelled'
      and o.created_at > now() - make_interval(hours => dh) order by o.id desc limit 1;
    if found then
      if prev.status in ('new','confirming') then
        update public.orders set updated_at = now(),
          flags = coalesce(orders.flags,'[]'::jsonb) || jsonb_build_array(jsonb_build_object('k','dup','at',now(),
            't', case when (select string_agg((x->>'ref')||'×'||(x->>'qty'), ',' order by x->>'ref') from jsonb_array_elements(fixed) x)
                          = (select string_agg((x->>'ref')||'×'||(x->>'qty'), ',' order by x->>'ref') from jsonb_array_elements(prev.items) x)
                      then 'أعاد الزبون إرسال نفس الطلبية'
                      else 'أرسل الزبون طلبية أخرى: '||(select string_agg((x->>'ref')||' ×'||(x->>'qty'), '، ') from jsonb_array_elements(fixed) x)||' ('||public.tg_money(tot)||')' end)),
          history = orders.history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'resent', 'items', fixed, 'total', tot))
        where id = prev.id;
        return prev.id;
      end if;
      fl := fl || jsonb_build_array(jsonb_build_object('k','again','t','للزبون طلبية أخرى قبل قليل (#'||prev.id||')'));
    end if;
  end if;
  -- 2) bot signs
  if coalesce(fr->>'bots','true') <> 'false' then
    if hp is not null then fl := fl || jsonb_build_array(jsonb_build_object('k','bot','t','بوت محتمل: ملأ خانة مخفية'));
    elsif ft is not null and ft < 3 then fl := fl || jsonb_build_array(jsonb_build_object('k','bot','t','بوت محتمل: مُلئت الاستمارة في '||round(ft)||' ثوانٍ'));
    end if;
  end if;
  -- 3) many phones from the same device / internet today
  if v_dev is not null or v_ip is not null then
    select count(distinct public.dz_phone(o.customer->>'phone')) into n from public.orders o
      where o.store_id = store and o.created_at > now() - interval '24 hours' and public.dz_phone(o.customer->>'phone') <> ph
        and ((v_dev is not null and o.dev = v_dev) or (v_ip is not null and o.ip = v_ip));
    if n >= 2 then fl := fl || jsonb_build_array(jsonb_build_object('k','device','t',(n+1)||' أرقام هاتف مختلفة من نفس الجهاز أو الإنترنت اليوم')); end if;
  end if;
  -- 4) blacklist and odd names
  select blacklist_reason into nm from public.customers c where c.store_id = store and c.phone = ph and c.blacklist;
  if found then fl := fl || jsonb_build_array(jsonb_build_object('k','black','t','زبون في القائمة السوداء'||coalesce(': '||nullif(nm,''),''))); end if;
  nm := trim(customer->>'name');
  if length(regexp_replace(nm, '[^[:alpha:]]', '', 'g')) < 3 or nm ~ '(.)\1\1\1' then fl := fl || jsonb_build_array(jsonb_build_object('k','name','t','اسم غير طبيعي: '||left(nm,40))); end if;
  insert into public.orders(store_id, customer, items, total, shipping, shipping_company, history, flags, ip, dev)
  values (store, customer, fixed, tot, coalesce((sf->>'fee')::int,0), sf->>'company', jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')),
    case when jsonb_array_length(fl) > 0 then fl end, v_ip, v_dev)
  returning id into oid;
  return oid;
end $$;

