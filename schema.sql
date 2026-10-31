-- =====================================================================
-- Controle de Refação · Extiminas — esquema do Supabase
-- Rode este arquivo UMA vez em: Supabase > SQL Editor > New query > Run
-- É seguro rodar de novo (usa "if not exists" / "or replace").
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Perfis: quem é gestor, equipe ou TV
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id         uuid primary key references auth.users(id) on delete cascade,
  nome       text not null default '',
  papel      text not null default 'equipe' check (papel in ('equipe', 'gestor', 'tv')),
  criado_em  timestamptz not null default now()
);

-- Papel do usuário logado. SECURITY DEFINER evita recursão nas políticas.
create or replace function public.papel_atual()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select papel from public.perfis where id = auth.uid()
$$;

-- Todo usuário novo ganha um perfil "equipe" automaticamente.
create or replace function public.novo_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfis (id, nome)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'nome', ''), split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.novo_usuario();

-- Usuários que já existiam antes deste script.
insert into public.perfis (id, nome)
select id, split_part(email, '@', 1) from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Refações
-- ---------------------------------------------------------------------
create table if not exists public.refacoes (
  id      uuid primary key default gen_random_uuid(),
  data    date    not null default current_date,
  ped     text    not null,
  lay     text    not null default '',
  setor   text    not null,
  sub     text    not null default '',   -- base (chapa)
  film    text    not null default '',   -- material aplicado
  mat     text    not null default '',   -- campo antigo (registros legados)
  metros  numeric not null check (metros > 0 and metros < 100000),
  larg    numeric,
  alt     numeric,
  un      text    not null default 'm' check (un in ('m', 'cm')),
  qtd     integer not null default 1 check (qtd >= 1 and qtd < 100000),
  lam     boolean not null default false,
  lam_t   text    not null default '' check (lam_t in ('', 'comum', 'overlay')),
  mot     text    not null default '',
  criado  bigint  not null default (extract(epoch from now()) * 1000)::bigint,
  por     uuid    default auth.uid() references auth.users(id) on delete set null
);

create index if not exists refacoes_data_idx  on public.refacoes (data desc);
create index if not exists refacoes_setor_idx on public.refacoes (setor);

-- ---------------------------------------------------------------------
-- 3. Configurações (preços por m² e responsáveis por setor)
-- ---------------------------------------------------------------------
create table if not exists public.config (
  chave          text primary key,
  valor          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. Segurança (Row Level Security) — o que cada papel pode fazer
--    equipe : só REGISTRAR refações (não lê nada, não vê preços)
--    gestor : tudo
--    tv     : só LER refações (nunca preços)
-- ---------------------------------------------------------------------
alter table public.perfis    enable row level security;
alter table public.refacoes  enable row level security;
alter table public.config    enable row level security;

drop policy if exists "ver o proprio perfil"    on public.perfis;
drop policy if exists "gestor ve perfis"        on public.perfis;
drop policy if exists "gestor altera perfis"    on public.perfis;
drop policy if exists "equipe registra"         on public.refacoes;
drop policy if exists "gestor e tv leem"        on public.refacoes;
drop policy if exists "gestor exclui"           on public.refacoes;
drop policy if exists "gestor controla config"  on public.config;

create policy "ver o proprio perfil" on public.perfis
  for select to authenticated
  using (id = auth.uid());

create policy "gestor ve perfis" on public.perfis
  for select to authenticated
  using (public.papel_atual() = 'gestor');

create policy "gestor altera perfis" on public.perfis
  for update to authenticated
  using (public.papel_atual() = 'gestor')
  with check (public.papel_atual() = 'gestor');

create policy "equipe registra" on public.refacoes
  for insert to authenticated
  with check (por = auth.uid() and public.papel_atual() in ('equipe', 'gestor'));

create policy "gestor e tv leem" on public.refacoes
  for select to authenticated
  using (public.papel_atual() in ('gestor', 'tv'));

create policy "gestor exclui" on public.refacoes
  for delete to authenticated
  using (public.papel_atual() = 'gestor');

create policy "gestor controla config" on public.config
  for all to authenticated
  using (public.papel_atual() = 'gestor')
  with check (public.papel_atual() = 'gestor');

-- Visitante sem login não acessa nada.
revoke all on public.perfis, public.refacoes, public.config from anon;

-- ---------------------------------------------------------------------
-- 5. Atualização em tempo real do painel e da TV
-- ---------------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.refacoes;
exception when duplicate_object then
  null;
end $$;

-- ---------------------------------------------------------------------
-- 6. PRÓXIMO PASSO (rode depois de criar o seu usuário em Authentication):
--    troque o e-mail e rode só esta linha para virar gestor.
-- ---------------------------------------------------------------------
-- update public.perfis set papel = 'gestor'
--  where id = (select id from auth.users where email = 'SEU_EMAIL_AQUI');
--
-- Conta da TV (opcional):
-- update public.perfis set papel = 'tv'
--  where id = (select id from auth.users where email = 'EMAIL_DA_TV_AQUI');
