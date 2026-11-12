-- ═══════════════════════════════════════════════════════════════
--  Aélythèque — améliorations (lot 2)
--  À coller dans Supabase : SQL Editor > New query > Run.
--  À lancer APRÈS les 3 autres fichiers SQL (déjà fait chez toi). Sans danger si relancé.
--
--  Ajoute :
--   • une date de fin de visibilité pour un outil (retrait programmé)
--   • un bandeau d'annonce affiché en haut de la page
--   • des statistiques anonymes (clics par outil, vidéos lues) — aucune donnée personnelle
--   • un import Excel « tout ou rien » (plus de risque de doublons si ça coupe en route)
-- ═══════════════════════════════════════════════════════════════

-- 1. Retrait programmé : l'outil disparaît tout seul à cette date (null = jamais)
alter table public.tools add column if not exists end_at timestamptz;

-- 2. Réglages (bandeau d'annonce) — lus et écrits uniquement par l'admin
create table if not exists public.settings (
  key   text primary key,
  value text not null default ''
);
alter table public.settings enable row level security;
drop policy if exists "admin tout" on public.settings;
create policy "admin tout" on public.settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.settings from anon;

-- 3. Statistiques anonymes : seulement « quel outil / quelle vidéo », jamais « qui »
create table if not exists public.events (
  id   bigserial primary key,
  kind text not null check (kind in ('open', 'video')),
  ref  text not null,
  at   timestamptz not null default now()
);
create index if not exists events_idx on public.events (kind, ref, at);
alter table public.events enable row level security;
drop policy if exists "admin lit" on public.events;
create policy "admin lit" on public.events for select to authenticated using (public.is_admin());
revoke all on public.events from anon;

create or replace function public.track(p_kind text, p_ref text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if p_kind not in ('open', 'video') or p_ref is null or length(p_ref) > 64 then return; end if;
  -- garde-fou : pas plus de 600 événements par minute (évite qu'on inonde la table)
  if (select count(*) from public.events where at > now() - interval '1 minute') > 600 then return; end if;
  insert into public.events (kind, ref) values (p_kind, p_ref);
  if random() < 0.01 then delete from public.events where at < now() - interval '400 days'; end if;
end;
$$;
grant execute on function public.track(text, text) to anon, authenticated;

create or replace function public.get_stats(p_days int default 30)
returns table (kind text, ref text, n bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur.'; end if;
  return query
    select e.kind, e.ref, count(*)::bigint
    from public.events e
    where e.at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)))
    group by e.kind, e.ref
    order by count(*) desc;
end;
$$;
grant execute on function public.get_stats(int) to authenticated;

-- 4. Import Excel « tout ou rien » : remplace tous les identifiants en une seule opération
create or replace function public.replace_credentials(p_rows jsonb)
returns int language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur.'; end if;
  delete from public.credentials where true;
  insert into public.credentials (store_id, tool_id, app, login, password, note, position)
  select nullif(r ->> 'store_id', '')::uuid,
         nullif(r ->> 'tool_id', '')::uuid,
         r ->> 'app',
         coalesce(r ->> 'login', ''),
         coalesce(r ->> 'password', ''),
         nullif(r ->> 'note', ''),
         coalesce((r ->> 'position')::int, 0)
  from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.replace_credentials(jsonb) to authenticated;

-- 5. Liste publique : version finale (vidéos + tutos généraux + bandeau + retrait programmé)
create or replace function public.get_tools()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'now', now(),
    'banner', (select nullif(btrim(s.value), '') from public.settings s where s.key = 'banner'),
    'tools', coalesce(jsonb_agg(to_jsonb(x) order by x.position, x.created_at), '[]'::jsonb),
    'general', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'title', g.title, 'url', g.url,
               'poster', g.poster, 'duration', g.duration_s)
             order by g.position, g.created_at), '[]'::jsonb)
      from public.tool_videos g where g.tool_id is null
    )
  )
  from (
    select
      id, position, created_at, color, release_at, teaser,
      locked,
      case when locked then 'Nouvel outil'       else name  end as name,
      case when locked then 'Bientôt disponible' else descr end as descr,
      case when locked then null else url   end as url,
      case when locked then null else icon  end as icon,
      case when locked then null else image end as image,
      case when locked then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', v.id, 'title', v.title, 'url', v.url,
                 'poster', v.poster, 'duration', v.duration_s)
               order by v.position, v.created_at)
        from public.tool_videos v where v.tool_id = s.id
      ), '[]'::jsonb) end as videos
    from (
      select t.*, (t.release_at is not null and t.release_at > now()) as locked
      from public.tools t
      where t.active and (t.end_at is null or t.end_at > now())
    ) s
  ) x;
$$;
grant execute on function public.get_tools() to anon, authenticated;

-- 6. Identifiants : un outil retiré ou arrivé à échéance n'expose plus les siens
create or replace function public.get_credentials(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ip    text;
  v_store public.stores;
  v_fails int;
begin
  begin
    v_ip := coalesce(nullif(btrim(split_part(
              (current_setting('request.headers', true)::jsonb) ->> 'x-forwarded-for', ',', 1)), ''), 'inconnu');
  exception when others then
    v_ip := 'inconnu';
  end;

  select count(*) into v_fails from public.cred_attempts
   where ip = v_ip and at > now() - interval '10 minutes';
  if v_fails >= 8 then
    raise exception 'Trop de tentatives. Réessaie dans quelques minutes.';
  end if;

  if p_code is null or btrim(p_code) = '' then
    return null;
  end if;

  select * into v_store from public.stores where lower(btrim(code)) = lower(btrim(p_code));
  if not found then
    delete from public.cred_attempts where at < now() - interval '1 day';
    insert into public.cred_attempts (ip) values (v_ip);
    perform pg_sleep(0.6);
    return null;
  end if;

  return jsonb_build_object(
    'store', v_store.name,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'app', c.app, 'login', c.login, 'password', c.password,
               'note', c.note, 'tool_id', c.tool_id)
             order by c.position, c.created_at)
      from public.credentials c
      left join public.tools t on t.id = c.tool_id
      where (c.store_id is null or c.store_id = v_store.id)
        and (t.id is null or (t.active
                              and (t.release_at is null or t.release_at <= now())
                              and (t.end_at is null or t.end_at > now())))
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.get_credentials(text) to anon, authenticated;
