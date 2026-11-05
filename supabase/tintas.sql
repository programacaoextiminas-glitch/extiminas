-- =====================================================================
-- Extiminas · Controle de Tintas — esquema do Supabase
-- Rode DEPOIS do schema.sql, UMA vez, em: Supabase > SQL Editor > New query > Run
-- É seguro rodar de novo.
--
-- Quem pode o quê (regras no banco, não só na tela):
--   gestor                      : tudo (painel, histórico, configurar)
--   usuário com perfis.tintas   : só o PAINEL — lê saldos, retira/entra/conta
--     (ex.: impressao@...)        frascos e marca compra. NÃO lê o histórico e
--                                 NÃO altera máquinas, cores nem regras.
--   qualquer outro usuário      : nenhum acesso às tabelas de tintas
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Permissão de tintas no perfil
-- ---------------------------------------------------------------------
alter table public.perfis add column if not exists tintas boolean not null default false;

create or replace function public.pode_tintas()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select papel = 'gestor' or tintas from public.perfis where id = auth.uid()), false)
$$;

-- ---------------------------------------------------------------------
-- 2. Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.tinta_maquinas (
  id         text primary key check (id ~ '^[a-z0-9-]{1,60}$'),
  nome       text not null check (char_length(nome) between 1 and 60),
  ordem      integer not null default 0,
  seguranca  integer check (seguranca between 0 and 99),   -- padrão da máquina
  alerta     integer check (alerta between 0 and 99)       -- "avisar em (ou menos)"
);

create table if not exists public.tinta_cores (
  maquina_id   text not null references public.tinta_maquinas(id) on delete cascade on update cascade,
  chave        text not null check (chave ~ '^[a-z0-9-]{1,60}$'),
  nome         text not null check (char_length(nome) between 1 and 40),
  ordem        integer not null default 0,
  qtd          integer not null default 0 check (qtd >= 0),
  lotes        jsonb   not null default '[]'::jsonb,       -- [{"val":"2027-05","qtd":3}, ...]
  comprado     boolean not null default false,
  comprado_em  timestamptz,
  seguranca    integer check (seguranca between 0 and 99), -- da cor; vazio = padrão da máquina
  alerta       integer check (alerta between 0 and 99),
  versao       integer not null default 0,                 -- evita duas pessoas sobrescreverem uma à outra
  primary key (maquina_id, chave)
);

create table if not exists public.tinta_config (
  id         integer primary key default 1 check (id = 1),
  dias_aviso integer not null default 60 check (dias_aviso between 1 and 365)
);
insert into public.tinta_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.tinta_movs (
  id            uuid primary key default gen_random_uuid(),
  ts            timestamptz not null default now(),
  maquina_id    text not null,
  maquina_nome  text not null default '',
  cor           text not null,
  cor_nome      text not null default '',
  tipo          text not null check (tipo in ('saida', 'entrada', 'ajuste', 'descarte')),
  delta         integer not null,
  saldo         integer not null,
  validade      text not null default '',
  pedido        text not null default '',
  operador      text not null default '',
  por           uuid default auth.uid() references auth.users(id) on delete set null
);
create index if not exists tinta_movs_ts_idx on public.tinta_movs (ts desc);

-- ---------------------------------------------------------------------
-- 3. Segurança (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.tinta_maquinas enable row level security;
alter table public.tinta_cores    enable row level security;
alter table public.tinta_config   enable row level security;
alter table public.tinta_movs     enable row level security;

drop policy if exists "tintas: ler maquinas"     on public.tinta_maquinas;
drop policy if exists "tintas: gestor maquinas"  on public.tinta_maquinas;
drop policy if exists "tintas: ler cores"        on public.tinta_cores;
drop policy if exists "tintas: gestor cores"     on public.tinta_cores;
drop policy if exists "tintas: ler config"       on public.tinta_config;
drop policy if exists "tintas: gestor config"    on public.tinta_config;
drop policy if exists "tintas: gestor historico" on public.tinta_movs;

-- Painel: quem tem acesso de tintas LÊ máquinas, cores e a regra de validade.
create policy "tintas: ler maquinas" on public.tinta_maquinas
  for select to authenticated using (public.pode_tintas());
create policy "tintas: ler cores" on public.tinta_cores
  for select to authenticated using (public.pode_tintas());
create policy "tintas: ler config" on public.tinta_config
  for select to authenticated using (public.pode_tintas());

-- Configurar: só gestor altera máquinas, cores e regras.
create policy "tintas: gestor maquinas" on public.tinta_maquinas
  for all to authenticated
  using (public.papel_atual() = 'gestor') with check (public.papel_atual() = 'gestor');
create policy "tintas: gestor cores" on public.tinta_cores
  for all to authenticated
  using (public.papel_atual() = 'gestor') with check (public.papel_atual() = 'gestor');
create policy "tintas: gestor config" on public.tinta_config
  for all to authenticated
  using (public.papel_atual() = 'gestor') with check (public.papel_atual() = 'gestor');

-- Histórico: só gestor lê. Ninguém grava direto: o registro entra pelas funções abaixo.
create policy "tintas: gestor historico" on public.tinta_movs
  for select to authenticated using (public.papel_atual() = 'gestor');

revoke all on public.tinta_maquinas, public.tinta_cores, public.tinta_config, public.tinta_movs from anon;
revoke insert, update, delete on public.tinta_movs from authenticated;

-- ---------------------------------------------------------------------
-- 4. Funções do painel (único caminho de escrita de quem não é gestor)
-- ---------------------------------------------------------------------

-- Registra retirada, entrada, contagem ou descarte de uma cor. O saldo e a
-- diferença são calculados aqui no servidor; p_versao é a versão que a tela viu.
create or replace function public.tinta_mover(
  p_maquina text, p_cor text, p_tipo text, p_lotes jsonb,
  p_validade text, p_pedido text, p_operador text, p_versao integer,
  p_limpar_compra boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c      public.tinta_cores;
  m      public.tinta_maquinas;
  e      jsonb;
  limpos jsonb;
  total  integer;
begin
  if not public.pode_tintas() then
    raise exception 'sem_acesso' using errcode = '42501';
  end if;
  if p_tipo not in ('saida', 'entrada', 'ajuste', 'descarte') then
    raise exception 'tipo_invalido';
  end if;
  if p_lotes is null or jsonb_typeof(p_lotes) <> 'array' or jsonb_array_length(p_lotes) > 40 then
    raise exception 'lotes_invalidos';
  end if;

  for e in select * from jsonb_array_elements(p_lotes) loop
    if jsonb_typeof(e) <> 'object'
       or coalesce(e ->> 'qtd', '') !~ '^[0-9]{1,3}$'
       or coalesce(e ->> 'val', '') !~ '^([0-9]{4}-(0[1-9]|1[0-2]))?$' then
      raise exception 'lotes_invalidos';
    end if;
  end loop;

  select * into c from public.tinta_cores
   where maquina_id = p_maquina and chave = p_cor for update;
  if not found then
    raise exception 'cor_nao_encontrada';
  end if;
  if c.versao <> p_versao then
    raise exception 'conflito' using errcode = '40001';
  end if;
  select * into m from public.tinta_maquinas where id = p_maquina;

  select coalesce(jsonb_agg(jsonb_build_object('val', coalesce(x ->> 'val', ''), 'qtd', (x ->> 'qtd')::int)), '[]'::jsonb),
         coalesce(sum((x ->> 'qtd')::int), 0)
    into limpos, total
    from jsonb_array_elements(p_lotes) x
   where (x ->> 'qtd')::int > 0;

  if p_tipo in ('saida', 'descarte') and total >= c.qtd then
    raise exception 'saldo_invalido';
  end if;
  if p_tipo = 'entrada' and total <= c.qtd then
    raise exception 'saldo_invalido';
  end if;

  update public.tinta_cores
     set lotes = limpos,
         qtd = total,
         versao = versao + 1,
         comprado = case when p_limpar_compra then false else comprado end,
         comprado_em = case when p_limpar_compra then null else comprado_em end
   where maquina_id = p_maquina and chave = p_cor;

  insert into public.tinta_movs
    (maquina_id, maquina_nome, cor, cor_nome, tipo, delta, saldo, validade, pedido, operador, por)
  values
    (p_maquina, m.nome, p_cor, c.nome, p_tipo, total - c.qtd, total,
     left(coalesce(p_validade, ''), 7), left(coalesce(p_pedido, ''), 60), left(coalesce(p_operador, ''), 40), auth.uid());

  return jsonb_build_object('qtd', total, 'versao', c.versao + 1);
end;
$$;

-- Marca (ou desmarca) "compra solicitada" de uma cor.
create or replace function public.tinta_comprado(p_maquina text, p_cor text, p_valor boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.pode_tintas() then
    raise exception 'sem_acesso' using errcode = '42501';
  end if;
  update public.tinta_cores
     set comprado = coalesce(p_valor, false),
         comprado_em = case when coalesce(p_valor, false) then now() else null end
   where maquina_id = p_maquina and chave = p_cor;
  if not found then
    raise exception 'cor_nao_encontrada';
  end if;
end;
$$;

revoke all on function public.tinta_mover(text, text, text, jsonb, text, text, text, integer, boolean) from public, anon;
revoke all on function public.tinta_comprado(text, text, boolean) from public, anon;
grant execute on function public.tinta_mover(text, text, text, jsonb, text, text, text, integer, boolean) to authenticated;
grant execute on function public.tinta_comprado(text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Tempo real
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['tinta_maquinas', 'tinta_cores', 'tinta_config', 'tinta_movs'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then
      null;
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 6. Quem tem acesso ao painel de tintas (além dos gestores, que veem tudo)
--    Rode esta linha depois de criar o usuário em Authentication:
-- ---------------------------------------------------------------------
update public.perfis set tintas = true
 where id = (select id from auth.users where lower(email) = 'impressao@extiminas.com');
-- Para liberar outra conta, troque o e-mail:
-- update public.perfis set tintas = true
--  where id = (select id from auth.users where lower(email) = 'OUTRO_EMAIL_AQUI');
-- Para retirar o acesso: tintas = false.
