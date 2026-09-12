# CLAUDE.md

Contexto persistente para o Claude Code trabalhar neste repositório. Leia
isto por inteiro antes de tocar em qualquer arquivo.

## O que é este projeto

Infraestrutura como código em Ansible para um homelab de produção real
(AlmaLinux 10 bare-metal — Docker, nginx, Cloudflare Tunnel, painel de
servidores de jogo). É também o principal projeto de portfólio de um
estudante de Gestão de TI em transição para SysAdmin/DevOps — qualidade de
código e clareza de documentação importam tanto quanto o playbook rodar.

Leia `README.md` inteiro antes de qualquer mudança. Ele documenta a
arquitetura, o histórico de um incidente de segurança (credenciais
vazadas — seção 7) e uma lista de dívidas técnicas conhecidas (seção 8).
Não repita nenhum dos dois.

## Convenções que NÃO se negociam

- **Idioma**: todo comentário de código e toda mensagem de commit são em
  português do Brasil. Sem exceção, mesmo em correções pequenas.
- **Commits**: Conventional Commits (`feat`, `fix`, `chore`, `docs` +
  escopo entre parênteses). O corpo do commit explica o **porquê**, não
  repete o diff — o histórico deste repositório é usado deliberadamente
  como registro de investigação de causa raiz, não como changelog. Veja
  `git log` para o padrão exato de tom e estrutura já estabelecido.
- **Um commit, uma correção.** Não junte dois bugs não relacionados no
  mesmo commit, mesmo que tenham sido encontrados na mesma sessão.
- **Zero valor fixo fora de `group_vars/`.** Nenhum IP, domínio, UUID ou
  caminho literal em roles, templates ou playbooks — tudo referencia uma
  variável de `group_vars/all/main.yml` (verdade de produção) ou
  `group_vars/lab/main.yml` (exceções só do ambiente de teste).
- **Comentário em toda decisão não óbvia.** Este repositório é material
  de estudo do próprio autor — escreva pensando em alguém reabrindo o
  arquivo em seis meses sem lembrar do contexto.

## Nunca fazer

- **Nunca leia, edite ou exiba o conteúdo de `group_vars/all/vault.yml`
  ou `inventory.ini`.** Os dois estão no `.gitignore` de propósito —
  contêm segredo real e IP específico de ambiente. Não printe o conteúdo
  deles em nenhuma saída, log ou commit.
- **Nunca peça, armazene ou tente contornar a senha do vault.** Se
  precisar rodar o playbook de forma não interativa, pergunte ao usuário
  a senha na hora — não tente extraí-la de arquivo, variável de ambiente
  ou histórico de shell. (Já aconteceu de a senha real acabar salva sem
  querer num `.txt` em texto claro — não repita esse erro.)
- **Nunca enfraqueça um controle de segurança para fazer algo passar.**
  Se a correção de um bug esbarrar num boolean do SELinux, numa regra de
  firewall, ou numa flag de privilégio de container, **pare e pergunte**
  antes de relaxar a proteção. Isso vale mesmo que a alternativa pareça
  mais trabalhosa.
- **Nunca rode `git push --force` na branch `main`** sem confirmação
  explícita do usuário. Ela pode estar sendo lida por outra pessoa
  (recrutador, colaborador futuro).
- **Nunca aplique um patch antes de confirmar a causa raiz.** Ver seção
  "Como investigar um erro" abaixo — é o método usado em toda a história
  deste projeto e não é opcional.

## Estrutura do repositório

```
group_vars/all/main.yml     verdade de produção — toda variável não secreta
group_vars/all/vault.yml    segredos cifrados (NUNCA leia/edite isto)
group_vars/lab/main.yml     overrides só para hosts do grupo [lab]
inventory.ini               IPs reais (NUNCA leia isto — local, fora do git)
inventory.ini.example       modelo versionado, sem IP real

playbooks/setup.yml         convergência completa — idempotente, serve tanto
                             para host novo quanto para corrigir deriva
playbooks/services.yml      garante serviços/stacks de pé (pós-reboot)
playbooks/update.yml        manutenção: pacotes, imagens, limpeza
playbooks/diag.yml          diagnóstico somente leitura, com asserts reais

roles/common/      usuário, sudo, pacotes, hardening SSH
roles/tailscale/   acesso remoto pessoal via tailnet (não expõe porta nenhuma)
roles/storage/     montagem BTRFS cirúrgica (nunca sobrescreve fstab inteiro)
roles/docker/      engine + plugin compose
roles/selinux/     booleans de container + política customizada do ttyd
roles/firewall/    firewalld declarativo
roles/ingress/     nginx, cloudflared, ttyd
roles/media/       Jellyfin, Navidrome
roles/gameserver/  Pelican Panel, Wings, Playit
roles/filemanager/ FileBrowser (upload de arquivos remoto)

Vagrantfile                 VM de laboratório (KVM/libvirt) — ver seção abaixo
```

Ordem das roles em `setup.yml` importa e está comentada no próprio
arquivo — releia o comentário antes de reordenar qualquer coisa (já
corrigimos um bug real de ordem entre `docker` e `selinux`: os booleans
de container só existem depois que o pacote `container-selinux`, que vem
junto do `docker-ce`, está instalado).

## Ambiente de teste (SEMPRE use antes de tocar em produção)

Existe uma VM AlmaLinux 10 sob KVM/libvirt, definida no `Vagrantfile`, que
existe especificamente para você rodar qualquer coisa destrutiva sem
medo. O IP dela é atribuído por DHCP e pode mudar se a VM for recriada —
**não assuma um IP fixo**; confira em `inventory.ini` (grupo `[lab]`) ou
rode `vagrant ssh-config` para obter o atual.

```bash
ssh ratto@<ip-do-inventory.ini>          # chave já autorizada, sudo sem senha
ansible-playbook playbooks/setup.yml --limit lab --ask-vault-pass
```

Regras de uso:

- **Toda mudança em role/playbook é validada no laboratório antes de
  cogitar produção.** Sem exceção.
- **Rode sempre via playbook, não editando a VM manualmente** — editar a
  VM à mão só serve para diagnóstico; a correção de verdade sempre entra
  como task Ansible, porque o que está sendo validado é o playbook, não
  a VM em si.
- **`--check` não é 100% confiável para módulos de gerenciador de
  pacote** (`dnf`, `yum`, `package`). Já vimos o módulo `dnf` instalar
  pacotes de verdade mesmo em modo simulação, e também vimos o oposto —
  reportar `changed` sem persistir nada. Para validar mudanças em
  pacotes, rode sem `--check` direto no laboratório (é descartável,
  criado exatamente para isso).
- **Toda task `command`/`shell` de leitura pura precisa de
  `check_mode: false` + `changed_when: false`.** Esses módulos são
  pulados em simulação, e no ansible-core 2.21 a variável registrada não
  fica indefinida como antes: ela vem com `rc: 0` e `stdout` vazio. A
  omissão, portanto, não falha mais — ela produz um resultado plausível e
  errado, que é pior. Veja `roles/storage/tasks/main.yml` para o padrão de
  referência e o comentário completo, com a medição.
- **Teste de idempotência**: depois de qualquer correção, rode o
  playbook duas vezes seguidas. A segunda deve reportar `changed=0`,
  exceto para tasks explicitamente não-idempotentes por natureza (e
  essas precisam estar comentadas dizendo por quê).

### Rodar o playbook contra o laboratório sem editar `inventory.ini`

O `inventory.ini` é local e não se toca (ver "Nunca fazer"). Quando a VM
é recriada e ganha IP DHCP novo, pegue o IP com `vagrant ssh-config` e
passe-o na linha de comando em vez de editar o arquivo:

```bash
ansible-playbook playbooks/setup.yml --limit lab \
  -e ansible_host=<ip-atual> --ask-vault-pass
```

`--limit lab` mantém o `group_vars/lab/` aplicado; `-e ansible_host=`
só sobrescreve o endereço de conexão.

### Estado da validação no laboratório (revisar antes de assumir)

Numa VM recriada do zero, o `setup.yml` converge e é idempotente de ponta
a ponta (`changed=0` na segunda passada), **exceto o túnel do
cloudflared** — ver abaixo. O `services.yml` sobe as seis stacks e os
serviços nativos; o `wings` é o único que não fica de pé sozinho, porque
depende de um `config.yml` que o Pelican Panel só gera depois que um node
é criado pela interface. Isso é limitação de um laboratório sem jogo
configurado, não bug de playbook.

Confirmado de novo em 12/09/2026, depois da rodada de correções de
revisão de código: `setup.yml --skip-tags cloudflared` deu `changed=0` na
segunda passada e o `diag.yml` rodou sem falha não esperada. As duas
falhas que o `diag.yml` acusa no laboratório são legítimas e conhecidas:
`cloudflared inactive` (a unit nem existe enquanto a tag estiver pulada) e
`wings activating` — este último sai com `status=1` em laço de
`auto-restart` porque `/etc/pelican/config.yml` não existe, que é a mesma
limitação descrita no parágrafo acima, agora com o sintoma exato anotado.

### Rodada de 12/09/2026 — FileBrowser (`filemanager`) e Tailscale

Validado no laboratório, `--limit lab --tags filemanager,tailscale`:
`setup.yml` deu `changed=0` na segunda passada, o container do FileBrowser
subiu saudável (`HTTP 200`, login `admin/admin` da imagem rejeitado com
`403` — confirma que a senha veio do vault), e o `tailscale up` conectou o
host ao tailnet do usuário sem precisar de link de aprovação (conta com
aprovação automática de dispositivo). SSH via IP do tailnet testado e
funcionando a partir de outro host já no mesmo tailnet. `ausearch -m avc`
sem negações.

Dois bugs reais encontrados e corrigidos nesta rodada — detalhes completos
em README.md seção 6:
- FileBrowser roda com UID/GID fixos da própria imagem (1000:1000), não
  aceitando `{{ app_uid }}` do host como o Jellyfin aceita. Só não apareceu
  em produção porque lá `app_uid` também é 1000, por coincidência.
- A task de inicialização do banco do FileBrowser precisa rodar como root
  (não `become_user: {{ app_user }}`), porque os diretórios montados são
  donos do UID acima, não de `{{ app_user }}` — senão o `creates:` não
  detecta o banco já existente e tenta inicializar de novo.

Achado, não corrigido nesta rodada (ver README seção 8): `services.yml`
falha inteiro no laboratório com `cloudflared` pulado, porque a task de
serviços systemd não tem a mesma tolerância que o `diag.yml` já tem para
esse caso conhecido.

### Rotação de senha do MariaDB — RESOLVIDA em 12/09/2026 (a lição fica)

Situação encontrada logo depois da convergência de produção desta data: o
`group_vars/all/vault.yml` tinha sido rotacionado, mas **os usuários DENTRO do
MariaDB continuavam com as senhas antigas** — trocar no vault não altera
usuário de banco que já existe (README, seção 9). Medido no host na hora:
`AUTH_FALHOU` tanto para `pelican` quanto para `root`.

O detalhe perigoso: o painel *parecia* saudável, porque os containers rodavam
desde antes com as variáveis antigas em memória. Como o `services.yml` roda
`docker compose up -d` em todas as stacks, rodá-lo naquele estado teria
recriado o `pelican-panel` com a senha nova contra um banco que esperava a
antiga — derrubando o painel sem nenhum aviso prévio.

Duas coisas que só apareceram ao verificar em vez de assumir:

1. A senha antiga do root **não** era a mesma do usuário `pelican`. Um
   `ALTER USER` autenticando com a senha errada falha no login e não muda nada.
2. Existem **dois** root (`root@localhost` E `root@%`), além de
   `pelican@%`. Rotacionar só o `@localhost` deixaria uma conta root viva
   aceitando a senha comprometida. Liste as contas antes:
   `SELECT CONCAT(user,0x40,host) FROM mysql.global_priv;` — no MariaDB 10.4+
   a tabela é `global_priv`; `mysql.user` é view e pode nem existir.

Ordem que funcionou, e que vale repetir na próxima rotação:
`setup.yml --tags gameserver` (reescreve o compose a partir do vault) →
`ALTER USER` nas três contas, lendo as senhas novas do próprio compose
renderizado (assim nada é digitado nem colado) → `docker compose up -d` na
stack do painel para fechar a janela em que o app ainda usa a credencial
velha → conferir com `AUTH_OK`/`AUTH_FALHOU` e confirmar que a senha antiga
passou a ser **rejeitada**.

PENDENTE do mesmo assunto: o FileBrowser. O `creates:` da task de
inicialização impede que ela rode de novo, então rotacionar no vault não muda
a senha de um `filebrowser.db` que já existe. Para rotacionar de verdade,
apague o `filebrowser.db` (só enquanto ele não tiver usuários/dados) e rode
`--tags filemanager`.

**Nota de segurança:** a senha gerada para `vault_filebrowser_admin_password`
apareceu em texto claro no terminal do usuário durante o diagnóstico de um
erro (campo `cmd` de uma falha do Ansible) e ficou registrada na sessão de
chat usada para esta rodada. Rotacionar (`ansible-vault edit` + reaplicar)
antes de considerar esta credencial definitiva.

### Mapa de exposição do laboratório (medido em 12/09/2026)

Útil antes de concluir que "o serviço não está no ar": no laboratório,
**quase nada é alcançável pela rede — e isso é o desenho funcionando**.

| Serviço | Bind | Alcançável da LAN |
|---|---|---|
| nginx (site e painel) | `0.0.0.0:80` | não — firewalld REJEITA |
| Jellyfin | `0.0.0.0:8096` | não — firewalld REJEITA |
| ttyd | `127.0.0.1:7681` | não — loopback |
| Navidrome | `127.0.0.1:4533` | não — loopback |
| FileBrowser | `127.0.0.1:8080` | não — loopback |
| Pelican Panel | `127.0.0.1:8081` | não — loopback |
| MariaDB / Redis | rede do compose | não — sem porta publicada |
| SSH | `0.0.0.0:22` | sim |
| SFTP do Wings | `2022/tcp` liberado | porta aberta, mas nada escutando |

Em produção quem entra é o `cloudflared`, a partir de `localhost`. Como o
laboratório ainda não tem túnel, **não existe caminho de rede até esses
serviços** — testar pelo navegador exige um túnel SSH
(`ssh -N -L 8096:127.0.0.1:8096 ... ratto@<ip>`), que passa pelo mesmo
`localhost` que o cloudflared usaria, sem afrouxar o firewall.

Ao diagnosticar, distinga as duas recusas: `No route to host` é o
firewalld rejeitando; `Connection refused` é porta liberada sem ninguém
escutando. Confundir as duas leva a mexer no firewall quando o problema
era serviço fora do ar.

### Pendência: túnel próprio do laboratório (ainda não implementado)

O `ingress` aborta no laboratório em "credencial do túnel não existe":
`/etc/cloudflared/<uuid>.json` é segredo emitido pela Cloudflare e não
está na VM. **Decisão tomada:** o laboratório usa um túnel SEPARADO
(`xalabias-lab`), não o de produção — dois conectores no mesmo túnel
fazem a Cloudflare dividir o tráfego de produção com a VM. Falta:

1. `cloudflared tunnel login` + `cloudflared tunnel create xalabias-lab`
   na VM, e copiar a credencial para `/etc/cloudflared/<uuid>.json`.
2. Sobrescrever `cloudflare_tunnel_id` e `cloudflare_tunnel_name` em
   `group_vars/lab/main.yml` com os valores do túnel de laboratório.

Até isso existir, valide o resto com `--skip-tags cloudflared`.

**Tudo por terminal.** O cloudflared deste projeto é gerenciado 100% por
linha de comando — inclusive o roteamento de DNS
(`cloudflared tunnel route dns <túnel> <hostname>`). Não use o painel web
da Cloudflare para criar rota, nem para nada que o CLI já faça.

O `cloudflared` 2026.9.0 **já está instalado na VM** (a role chega a rodar
e só aborta na checagem de credencial), então o passo 1 começa direto no
`tunnel login`. Ele imprime uma URL e fica bloqueado esperando o callback
do navegador; esse callback **expira em poucos minutos** e o erro é
`Failed to fetch resource`. Se isso acontecer, `/root/.cloudflared/` fica
criado e vazio — não é estado corrompido, é só rodar o login de novo.

#### Nomes temporários planejados para o laboratório

Prefixo `lab-`, nenhum colidindo com os de produção (a lista de produção
está em `cloudflare_ingress`, em `group_vars/all/main.yml`):

| Temporário | Destino |
|---|---|
| `lab.<domínio>`          | `localhost:80` (site) |
| `lab-painel.<domínio>`   | `localhost:8081` (painel, SEM passar pelo nginx) |
| `lab-jellyfin.<domínio>` | `localhost:8096` |
| `lab-music.<domínio>`    | `localhost:4533` |
| `lab-files.<domínio>`    | `localhost:8080` |
| `lab-ssh.<domínio>`      | `localhost:7681` |

Esses nomes entram como override de `cloudflare_ingress` em
`group_vars/lab/main.yml` — o `config.yml` continua saindo do template
`cloudflared-config.yml.j2`, sem arquivo escrito à mão.

O painel aponta direto para `:8081` de propósito: o `server_name` do
nginx é `painel.<domínio>`, então um nome `lab-painel` cairia no
catch-all `return 444`. Ir direto no container evita editar config de
nginx só para teste.

#### Bloqueio conhecido: `APP_URL` do painel é fixo

`pelican-compose.yml.j2` fixa `APP_URL=https://painel.{{ base_domain }}`.
Como o Laravel gera URL absoluta a partir disso, abrir o painel por
qualquer outro nome (incluindo `lab-painel`) redireciona para o domínio
de **produção** — ou seja, o teste de laboratório sai do laboratório.

Para testar o painel no lab é preciso antes transformar isso em variável
(ex.: `pelican_app_url`, com o valor de produção como padrão em
`group_vars/all/` e o de laboratório sobrescrito em `group_vars/lab/`) e
recriar o container do painel. Os outros cinco serviços não têm esse
problema e podem ser testados sem mudança nenhuma.

## Como investigar um erro (método obrigatório, não sugestão)

Este projeto foi construído inteiro com esse método, e ele já pagou o
próprio custo várias vezes — não pule etapa mesmo sob pressão de "a
correção óbvia provavelmente resolve":

1. **Reproduza o erro real** — rode o playbook, capture a mensagem
   completa. Erros do Ansible em módulos de alto nível costumam ser
   genéricos; quando for o caso, entre na VM e rode o comando de verdade
   em primeiro plano (ex.: `sudo dockerd --containerd=...` em vez de só
   `systemctl start docker`) para ver o erro original, não o resumo do
   systemd.
2. **Confirme a causa antes de escrever qualquer fix** — com comandos de
   diagnóstico direto na VM (`rpm -q`, `find /lib/modules/...`,
   `dnf list --available`, etc.). Não assuma; verifique.
3. **Pergunte-se se a causa é específica do laboratório ou já existia em
   produção escondida.** Vários bugs reais deste projeto só apareceram
   num host verdadeiramente limpo porque produção já tinha o pré-requisito
   instalado de uma configuração manual anterior ao Ansible — isso é
   material de comentário quando acontecer de novo (veja os blocos "BUG
   REAL, encontrado testando num host limpo" já existentes em
   `roles/docker/tasks/main.yml` como modelo de tom e estrutura).
4. **Escreva a correção como task idempotente**, nunca como script solto
   ou hack pontual. Comente o quê estava quebrado, por quê, e por que
   essa é a correção certa (não um remendo).
5. **Valide de novo** (rodar o playbook, idealmente duas vezes).
6. **Só então commite.**

## Antes de fazer commit

- `ansible-playbook <arquivo> --syntax-check` em qualquer playbook tocado.
- Confirme que nenhum segredo, IP real ou domínio literal entrou no diff:
  `git diff | grep -iE 'password|token|secret'` como checagem mínima.
- Mensagem de commit em português, Conventional Commits, corpo explicando
  o porquê. Um assunto por commit.
- Push para `origin main` só depois de o usuário confirmar que quer
  publicar — numa sessão de correção longa, é preferível perguntar uma
  vez ao final do que fazer push a cada commit individual.

## Quando parar e perguntar em vez de decidir sozinho

- Qualquer mudança que relaxe segurança (SELinux, firewall, privilégio de
  container, TLS, autenticação).
- Qualquer mudança que altere uma decisão de arquitetura já documentada
  no README (por exemplo, quem gerencia as regras de `iptables`: hoje é
  o Docker, coordenado com a role `firewall` — trocar isso é decisão de
  arquitetura, não bugfix).
- Qualquer coisa que exigiria editar `group_vars/all/main.yml` de um jeito
  que mudaria o comportamento em **produção**, não só no laboratório.
- Sempre que a correção mais simples for "desistir de testar isso" (pular
  uma verificação, aumentar um timeout genérico, comentar um assert). Se
  a tentação é essa, o problema provavelmente não foi entendido ainda.
