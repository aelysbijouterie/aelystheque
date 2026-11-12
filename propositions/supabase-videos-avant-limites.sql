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
-- 50 Mo max par fichier (limite du plan gratuit), formats vidéo + image de couverture.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', true, 52428800, array['video/mp4', 'video/webm', 'image/jpeg'])
on conflict (id) do update
  set public = true, file_size_limit = 52428800, allowed_mime_types = array['video/mp4', 'video/webm', 'image/jpeg'];

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
