-- ═══════════════════════════════════════════════════════════════
--  Aélythèque — INSTALLATION COMPLÈTE (les 4 fichiers SQL, dans l'ordre)
--  Sans danger à relancer à tout moment : ne supprime aucune donnée et
--  remet toujours la dernière version des fonctions (plus de risque
--  d'écraser une version récente en relançant un ancien fichier).
--  Fichier généré automatiquement à partir de :
--    supabase-setup.sql · supabase-videos.sql · supabase-identifiants.sql · supabase-ameliorations.sql
-- ═══════════════════════════════════════════════════════════════



-- ════════ supabase-setup.sql ════════

-- ═══════════════════════════════════════════════════════════════
--  Aélythèque — installation de la base (à coller dans Supabase :
--  menu "SQL Editor" > New query > Run). À exécuter UNE seule fois.
-- ═══════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- Qui a le droit d'administrer (rempli à l'étape 4 du LISEZ-MOI)
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.tools (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  descr       text not null default '',
  url         text not null,
  icon        text not null default '🔗',   -- emoji de secours
  image       text,                          -- lien ou chemin du favicon
  color       text,                          -- ex. #A87B27
  teaser      text,                          -- mini-aperçu 16px (pour le flou)
  position    int  not null default 0,
  active      boolean not null default true, -- false = retiré de la page
  release_at  timestamptz,                   -- null = visible tout de suite
  created_at  timestamptz not null default now()
);

alter table public.admins enable row level security;  -- aucune policy = fermé
alter table public.tools  enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
grant execute on function public.is_admin() to authenticated;

-- L'admin lit / écrit tout. Le public n'a AUCUN accès direct à la table.
drop policy if exists "admin tout" on public.tools;
create policy "admin tout" on public.tools
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Ce que voit le public : la liste, avec les outils pas encore sortis
-- MASQUÉS CÔTÉ SERVEUR (nom, lien et icône réels ne sortent pas de la base
-- avant l'heure → impossible de les "dé-flouter" avec F12).
-- L'heure de référence est celle du serveur, pas celle du téléphone.
create or replace function public.get_tools()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'now', now(),
    'tools', coalesce(jsonb_agg(to_jsonb(x) order by x.position, x.created_at), '[]'::jsonb)
  )
  from (
    select
      id, position, created_at, color, release_at, teaser,
      locked,
      case when locked then 'Nouvel outil'      else name  end as name,
      case when locked then 'Bientôt disponible' else descr end as descr,
      case when locked then null else url   end as url,
      case when locked then null else icon  end as icon,
      case when locked then null else image end as image
    from (
      select t.*, (t.release_at is not null and t.release_at > now()) as locked
      from public.tools t
      where t.active
    ) s
  ) x;
$$;
grant execute on function public.get_tools() to anon, authenticated;

-- Stockage des favicons (bucket public en lecture par lien direct, mais
-- sans "select" : personne ne peut lister les fichiers à l'avance).
insert into storage.buckets (id, name, public)
values ('icons', 'icons', true)
on conflict (id) do nothing;

drop policy if exists "icons admin ecrit"  on storage.objects;
drop policy if exists "icons admin modifie" on storage.objects;
drop policy if exists "icons admin supprime" on storage.objects;
create policy "icons admin ecrit" on storage.objects
  for insert to authenticated with check (bucket_id = 'icons' and public.is_admin());
create policy "icons admin modifie" on storage.objects
  for update to authenticated using (bucket_id = 'icons' and public.is_admin());
create policy "icons admin supprime" on storage.objects
  for delete to authenticated using (bucket_id = 'icons' and public.is_admin());

-- Tes 3 outils actuels (les images restent celles de ton dépôt GitHub)
insert into public.tools (name, descr, url, icon, image, color, position)
select * from (values
  ('Aurel''IA', 'Bibliothèque de procédures',
   'https://chatbot-alpha-sepia-22.vercel.app/', '📚', 'aureil-ia-icon.jpg', '#A87B27', 0),
  ('SIMONE', 'Recherche de références SIMONE A BORDEAUX',
   'https://recherche-reference-simone.netlify.app/', '🔍', 'simone-icon.jpg', '#A87B27', 1),
  ('TEMPO', 'Gestion des visuels opérations magasin',
   'https://pac-aelys.vercel.app/connexion-boutique', '🖼️', 'tempo.jpg', '#A87B27', 2)
) as v(name, descr, url, icon, image, color, position)
where not exists (select 1 from public.tools);


-- ════════ supabase-videos.sql ════════

-- ═══════════════════════════════════════════════════════════════
--  Aélythèque — vidéos de présentation / tutos
--  À coller dans Supabase : SQL Editor > New query > Run (une seule fois,
--  APRÈS supabase-setup.sql). Sans danger si relancé.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.tool_videos (
  id          uuid primary key default gen_random_uuid(),
  tool_id     uuid not null references public.tools(id) on delete cascade,
  title       text not null,
  url         text not null,          -- fichier MP4/WebM, ou lien YouTube / Vimeo / Loom
  poster      text,                   -- image de couverture (affichée instantanément)
  duration_s  int,                    -- durée en secondes (null = lien externe)
  position    int not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.tool_videos alter column tool_id drop not null;   -- null = tuto général (bibliothèque)
create index if not exists tool_videos_tool_idx on public.tool_videos (tool_id, position);

alter table public.tool_videos enable row level security;
drop policy if exists "admin tout" on public.tool_videos;
create policy "admin tout" on public.tool_videos
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Stockage des vidéos : lecture publique par lien direct (pas de listing),
-- 500 Mo max par fichier (le plan gratuit Supabase plafonne à 50 Mo : voir Storage > Settings), formats vidéo + image de couverture.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', true, 524288000, array['video/mp4', 'video/webm', 'image/jpeg'])
on conflict (id) do update
  set public = true, file_size_limit = 524288000, allowed_mime_types = array['video/mp4', 'video/webm', 'image/jpeg'];

drop policy if exists "videos admin ecrit"   on storage.objects;
drop policy if exists "videos admin modifie" on storage.objects;
drop policy if exists "videos admin supprime" on storage.objects;
create policy "videos admin ecrit" on storage.objects
  for insert to authenticated with check (bucket_id = 'videos' and public.is_admin());
create policy "videos admin modifie" on storage.objects
  for update to authenticated using (bucket_id = 'videos' and public.is_admin());
create policy "videos admin supprime" on storage.objects
  for delete to authenticated using (bucket_id = 'videos' and public.is_admin());

-- La liste publique renvoie maintenant aussi les vidéos de chaque outil
-- (jamais celles d'un outil pas encore sorti).
create or replace function public.get_tools()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'now', now(),
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
      where t.active
    ) s
  ) x;
$$;
grant execute on function public.get_tools() to anon, authenticated;


-- ════════ supabase-identifiants.sql ════════

-- ═══════════════════════════════════════════════════════════════
--  Aélythèque — gestionnaire d'identifiants / mots de passe par magasin
--  À coller dans Supabase : SQL Editor > New query > Run (une seule fois,
--  APRÈS supabase-setup.sql). Sans danger si relancé.
--
--  Sécurité : les identifiants ne sont JAMAIS dans la page publique.
--  Ils restent dans la base ; le public ne peut les obtenir qu'en donnant
--  le code d'UN magasin, et ne reçoit que les identifiants de CE magasin
--  (+ ceux communs à tous les magasins).
-- ═══════════════════════════════════════════════════════════════

-- Magasins : un nom + un code d'accès (lu uniquement par l'admin)
create table if not exists public.stores (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  code       text not null,
  created_at timestamptz not null default now()
);
create unique index if not exists stores_name_uq on public.stores (lower(name));
create unique index if not exists stores_code_uq on public.stores (lower(btrim(code)));

-- Identifiants : store_id vide = commun à tous les magasins
create table if not exists public.credentials (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid references public.stores(id) on delete cascade,
  tool_id    uuid references public.tools(id)  on delete set null,   -- facultatif : relie à un outil de la grille
  app        text not null,
  login      text not null default '',
  password   text not null default '',
  note       text,
  position   int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists credentials_store_idx on public.credentials (store_id, position);

-- Journal des codes erronés (limite les tentatives au hasard)
create table if not exists public.cred_attempts (
  id bigserial primary key,
  ip text not null,
  at timestamptz not null default now()
);
create index if not exists cred_attempts_idx on public.cred_attempts (ip, at);

alter table public.stores        enable row level security;
alter table public.credentials   enable row level security;
alter table public.cred_attempts enable row level security;

drop policy if exists "admin tout" on public.stores;
create policy "admin tout" on public.stores
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin tout" on public.credentials;
create policy "admin tout" on public.credentials
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
-- cred_attempts : aucune policy → inaccessible, sauf à la fonction ci-dessous

revoke all on public.stores, public.credentials, public.cred_attempts from anon;

-- Appelée par la page publique avec le code d'un magasin.
-- Renvoie null si le code est faux, sinon { store, items[] } pour CE magasin uniquement.
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
        -- un outil pas encore sorti (ou retiré) ne fuite jamais par ses identifiants
        and (t.id is null or (t.active and (t.release_at is null or t.release_at <= now())))
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.get_credentials(text) to anon, authenticated;


-- ════════ supabase-ameliorations.sql ════════

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
