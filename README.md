# Extiminas · Sistema interno

Abas do site: **Refação** (registro de perdas de insumos, painel de custos e modo TV) e **Tintas** (estoque de frascos de tinta por máquina, com validade).

- **Site:** HTML puro (sem build), publicado no **GitHub Pages**
- **Dados e login:** **Supabase** (Postgres + Auth + Realtime)

```
index.html                  # o site (abas) e a aba Refação
tintas.html                 # a aba Tintas (abre dentro do index.html)
config.js                   # URL e chave pública do Supabase (você preenche)
supabase/schema.sql         # tabelas, login e regras de acesso (rodar 1x)
supabase/tintas.sql         # tabelas e regras da aba Tintas (rodar 1x, depois do schema.sql)
```

## Quem pode o quê

| Papel    | Registrar refação | Ver painel e histórico | Ver/alterar preços | Excluir |
|----------|:-:|:-:|:-:|:-:|
| `equipe` | ✅ | ❌ | ❌ | ❌ |
| `gestor` | ✅ | ✅ | ✅ | ✅ |
| `tv`     | ❌ | ✅ (só `#tv`) | ❌ | ❌ |

Essas regras ficam **no banco** (Row Level Security), não só na tela: mesmo quem
abrir o console do navegador não consegue ler preços nem o histórico sem ser gestor.

### Aba Tintas

| Quem | Painel (ver saldos, retirar, entrada, contagem, marcar compra) | Histórico | Configurar (máquinas, cores, regras) |
|------|:-:|:-:|:-:|
| `gestor` | ✅ | ✅ | ✅ |
| usuário com `perfis.tintas = true` (`impressao@extiminas.com`) | ✅ | ❌ | ❌ |
| qualquer outro usuário | ❌ (a aba nem aparece) | ❌ | ❌ |

Quem só tem acesso ao painel não lê o histórico nem altera máquinas/cores/regras: as
movimentações entram por funções do banco (`tinta_mover`, `tinta_comprado`), que conferem a
permissão e o saldo no servidor. Para liberar outra conta, troque o e-mail na última linha de
`supabase/tintas.sql` e rode só ela:

```sql
update public.perfis set tintas = true
 where id = (select id from auth.users where lower(email) = 'OUTRO_EMAIL_AQUI');
```

---

## Passo a passo

### 1. Criar o projeto no Supabase
1. Entre em <https://supabase.com> e crie um projeto (região **South America (São Paulo)**).
2. Em **Authentication → Sign In / Providers → Email**, deixe e-mail/senha ligado e
   **desligue "Allow new users to sign up"** (assim só entra quem você convidar).
   Em **Confirm email**, pode desligar para simplificar.
3. Em **SQL Editor → New query**, cole o conteúdo de `supabase/schema.sql` e clique **Run**.

### 1b. Ativar a aba Tintas
No **SQL Editor**, rode `supabase/tintas.sql`. (Os saldos e o histórico iniciais não ficam no repositório, que é público: foram importados direto no Supabase.)
(O usuário `impressao@extiminas.com` precisa já existir em Authentication; se for criado depois,
rode de novo a última linha do `tintas.sql`.)

### 2. Criar os usuários
Em **Authentication → Users → Add user → Create new user**, crie:
- o seu usuário (gestor);
- um usuário por pessoa da equipe (ou um compartilhado por setor);
- opcionalmente um usuário para a TV.

Depois, no **SQL Editor**, torne-se gestor (troque o e-mail):

```sql
update public.perfis set papel = 'gestor'
 where id = (select id from auth.users where email = 'SEU_EMAIL_AQUI');
```

Para a conta da TV, a mesma coisa com `papel = 'tv'`.

### 3. Preencher o `config.js`
Em **Project Settings → API**, copie a **Project URL** e a **anon public key** para o `config.js`.
> A chave `anon` é pública por desenho. **Nunca** use a `service_role` aqui.

### 4. Subir para o GitHub
```bash
cd extiminas
git init
git add .
git commit -m "Controle de refação: versão com Supabase"
git branch -M main
git remote add origin https://github.com/SEU_USUARIO/extiminas.git
git push -u origin main
```

### 5. Publicar com GitHub Pages
No repositório: **Settings → Pages → Build and deployment → Source: Deploy from a branch →
Branch: `main` / `(root)` → Save.** Em ~1 minuto o site fica em
`https://SEU_USUARIO.github.io/extiminas/`.

### 6. Liberar o endereço no Supabase
Em **Authentication → URL Configuration**, coloque o endereço do GitHub Pages em
**Site URL**.

---

## Modo TV
Abra `https://SEU_USUARIO.github.io/extiminas/#tv` e entre com a conta da TV.
Atualiza sozinho (tempo real + a cada 60 s).

## Testar no seu computador
```bash
python3 -m http.server 8000      # e abra http://localhost:8000
```
Sem preencher o `config.js`, o app abre em **modo de teste** (nada é guardado).

## Cópia de segurança
No painel do gestor: **Cópia de segurança → Baixar histórico completo** gera um CSV para o Excel.
No Supabase também há backups diários automáticos nos planos pagos; no plano gratuito, baixe o CSV de tempos em tempos.

## Observações
- O projeto gratuito do Supabase **pausa após 7 dias sem uso**. Se isso for um problema, acesse o painel
  do Supabase de vez em quando ou use o plano Pro.
- Preços e responsáveis por setor ficam só no banco (tabela `config`, visível apenas ao gestor). Não os coloque no repositório, que é público.
- Os novos registros guardam o usuário que fez o login em "Registrado por".
- Para editar preços, materiais ou setores, altere as listas no início do `<script>` do `index.html`.
