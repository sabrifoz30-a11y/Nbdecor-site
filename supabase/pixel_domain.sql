-- Server events (Meta CAPI / TikTok) now report the shop's own domain as the event source URL.
do $$ declare f text; d text; begin
  foreach f in array array['capi_purchase','tiktok_purchase'] loop
    select pg_get_functiondef(('public.'||f)::regproc) into d;
    d := replace(d, 'https://sabrifoz30-a11y.github.io/Nbdecor-site/', 'https://styledecordz.store/');
    execute d;
  end loop;
end $$;
