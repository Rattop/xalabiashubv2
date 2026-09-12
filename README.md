# XalabiasHub

**Infraestrutura como Código para um homelab de produção, escrita em Ansible.**

AlmaLinux 10 em hardware bare-metal, provisionado do zero e mantido por
playbooks versionados. Sem passo manual, sem segredo em texto claro, sem
"funciona na minha máquina".

![Ansible](https://img.shields.io/badge/Ansible-2.15%2B-EE0000?logo=ansible&logoColor=white)
![AlmaLinux](https://img.shields.io/badge/AlmaLinux-10.2-0F4266?logo=almalinux&logoColor=white)
![SELinux](https://img.shields.io/badge/SELinux-enforcing-success)
![Licença](https://img.shields.io/badge/licen%C3%A7a-MIT-blue)

---

## Sobre este projeto e sobre mim

Sou **estudante de Gestão da Tecnologia da Informação**, em transição de
carreira para **SysAdmin / DevOps**. Trabalho hoje com recepção e auditoria
noturna em hotelaria, e este repositório é onde estudo infraestrutura de
verdade — não em laboratório descartável, mas num servidor que roda 24/7 e
que a minha casa realmente usa.

**Este README documenta tanto os acertos quanto os erros.** Existe uma seção
inteira sobre um incidente de credenciais vazadas que eu mesmo causei, e
outra sobre dívidas técnicas que ainda não resolvi. Isso é deliberado: acho
mais honesto — e mais útil para quem avalia — mostrar como eu diagnostico e
corrijo do que fingir que nunca errei.

O hardware é um notebook Acer de 2017 com Core i3 e 8 GB de RAM. A limitação
é proposital: obriga a pensar em consumo de recurso, e prova que a disciplina
de engenharia importa mais que o orçamento.

---

## 1. Arquitetura

```
                          Internet
                             │
                    ┌────────▼────────┐
                    │   Cloudflare    │  DNS, TLS, Access (autenticação)
                    └────────┬────────┘
                             │  túnel de SAÍDA
                             │  (nenhuma porta aberta no roteador)
┌────────────────────────────▼─────────────────────────────────────┐
│  HOST — AlmaLinux 10.2 · Acer Aspire ES1-572 · i3-7100U · 8 GB    │
│                                                                   │
│   cloudflared ──┬─► nginx :80 ──┬─► site estático                │
│                 │               └─► Pelican Panel (proxy)         │
│                 ├─► Jellyfin :8096      (vídeo, VAAPI)            │
│                 ├─► Navidrome :4533     (música)                  │
│                 ├─► Picard :5800        (metadados)               │
│                 ├─► ttyd :7681          (terminal web)            │
│                 └─► FileBrowser :8080   (upload de arquivos)      │
│                                                                   │
│   playit ──────────► servidores de jogo (TCP/UDP bruto)           │
│   wings ───────────► cria/destrói containers de jogo              │
│   tailscaled ──────► tailnet do usuário (acesso remoto pessoal,   │
│                       independente do túnel Cloudflare acima)     │
│                                                                   │
│   firewalld: só 22 e 2022 abertos para a LAN                      │
│   SELinux: enforcing, com política customizada para o ttyd        │
│                                                                   │
│   Armazenamento:  LVM/XFS (sistema)  ·  BTRFS 1,8 TB (mídia)      │
└───────────────────────────────────────────────────────────────────┘
```

**A decisão de arquitetura mais importante:** nenhuma porta é redirecionada
no roteador. O `cloudflared` e o `playit` abrem conexões de **saída** e o
tráfego volta por elas. Não existe superfície para escanear na internet, e é
por isso que o firewall pode manter 80, 7681 e 8096 fechados até para a rede
local — quem os acessa é o túnel, a partir de `localhost`. O Tailscale segue
a mesma lógica: conecta de saída e usa NAT traversal/DERP, sem porta nenhuma
para redirecionar ou escanear.

---

## 2. Estrutura do repositório

```
├── ansible.cfg              Configuração do Ansible (diff ligado por padrão)
├── inventory.ini            Hosts: prod (bare-metal) e lab (clone virtual)
├── deploy.sh                Wrapper: simula, confirma, aplica
├── requirements.yml         Collections necessárias
│
├── group_vars/all/
│   ├── main.yml             ÚNICA fonte de verdade da configuração
│   └── vault.yml            Segredos cifrados (não versionado)
│
├── playbooks/
│   ├── setup.yml            Convergência completa do host
│   ├── services.yml         Garante serviços e stacks de pé
│   ├── update.yml           Manutenção: pacotes, imagens, limpeza
│   └── diag.yml             Diagnóstico read-only, com verificações
│
└── roles/
    ├── common/              Pacotes, usuário, sudo, hardening SSH
    ├── tailscale/           Acesso remoto pessoal via tailnet
    ├── storage/             Montagem BTRFS via fstab cirúrgico
    ├── selinux/             Booleans + política customizada do ttyd
    ├── firewall/            firewalld declarativo
    ├── docker/              Engine e plugin compose
    ├── ingress/             nginx, cloudflared, ttyd
    ├── media/               Jellyfin, Navidrome, Picard
    ├── gameserver/          Pelican Panel, Wings, Playit
    └── filemanager/         FileBrowser (upload de arquivos)
```

---

## 3. Como usar

### Preparação (uma vez)

```bash
ansible-galaxy collection install -r requirements.yml

cp group_vars/all/vault.yml.example group_vars/all/vault.yml
openssl rand -base64 24        # rode uma vez para cada senha
ansible-vault encrypt group_vars/all/vault.yml
```

### Execução

```bash
# 1. SIMULE. Mostra o diff de cada arquivo, sem alterar nada.
ansible-playbook playbooks/setup.yml --limit lab --check --diff --ask-vault-pass

# 2. Aplique.
ansible-playbook playbooks/setup.yml --limit lab --ask-vault-pass

# 3. Confirme idempotência: a segunda execução deve dar changed=0.
ansible-playbook playbooks/setup.yml --limit lab --ask-vault-pass | tail -5
```

O `./deploy.sh setup --limit lab` embrulha os três passos e pede confirmação
explícita antes de aplicar.

### Trabalhar em partes

```bash
ansible-playbook playbooks/setup.yml --tags nginx,docker    # só isso
ansible-playbook playbooks/setup.yml --skip-tags ssh        # tudo menos isso
ansible-playbook playbooks/setup.yml --list-tasks           # o que rodaria
```

| Playbook | Quando usar |
|---|---|
| `setup.yml` | Host novo, ou corrigir deriva de configuração |
| `services.yml` | Depois de reboot; "voltar ao normal" |
| `update.yml` | Manutenção periódica |
| `diag.yml` | Quando algo quebra (read-only) |

---

## 4. Decisões de engenharia

### 4.1 Por que o `fstab` nunca é copiado inteiro

A versão anterior deste projeto fazia `copy: src=files/fstab dest=/etc/fstab`.
Isso copiava os UUIDs de `/`, `/boot` e `/home` da máquina de origem. Numa
reinstalação — o cenário que o projeto existe para suportar — o instalador
cria partições novas com UUIDs novos, e o fstab copiado apontaria para
volumes inexistentes. **O host não daria boot.**

Hoje só as linhas de mídia são gerenciadas, com `ansible.posix.mount`, que
edita o arquivo cirurgicamente.

*Princípio geral: quando existe um módulo que entende o **formato** do
arquivo, ele é mais seguro que sobrescrever o arquivo inteiro.*

### 4.2 Por que a política SELinux é `.te` e não `.pp`

O caminho fácil quando o SELinux bloqueia algo é desligá-lo. Este projeto
faz o contrário para o `ttyd`: uma política de **uma linha**, concedendo
exatamente uma transição de processo e nada mais.

Ela é versionada como `.te` (código-fonte legível) e compilada no host, não
como `.pp` (binário). O `.pp` depende da versão da política do sistema e
vira lixo silencioso na próxima atualização.

O contraste está documentado de propósito: o Jellyfin ainda usa
`label:disable`, e isso está listado como dívida, não escondido.

### 4.3 Por que os GIDs de vídeo são descobertos em tempo de execução

Para transcodificar por hardware, o Jellyfin precisa dos grupos `render` e
`video` do host. A tentação é escrever `group_add: [video, render]` — mas o
Docker resolve nomes de grupo **dentro** do container. O Jellyfin roda
Debian (`video` = 44) e o host é AlmaLinux (`video` = 39). Os números não
batem e o acesso ao dispositivo seria negado em silêncio.

A role descobre os GIDs numéricos com `getent group` e os injeta no compose.

### 4.4 Por que `--check` exigiu cuidado especial

Módulos `command` e `shell` **não executam** o comando em modo simulação — o
Ansible não tem como saber se um comando arbitrário é seguro. A task é pulada.

Toda task que apenas **coleta informação** para decidir outra coisa leva
`check_mode: false` (execute mesmo em simulação) junto de
`changed_when: false` (nunca reporte mudança).

**O motivo dessa regra mudou — e ficou mais grave.** Ela nasceu porque a
variável registrada ficava sem `.stdout` e sem `.rc`, e usá-la estourava erro
de atributo indefinido: uma falha barulhenta e imediata. Reconferido em
12/09/2026 contra o ansible-core 2.21.2, não é mais isso que acontece:

```
TASK [comando] ***  skipping: [localhost]
"r": { "rc": 0, "stdout": "", "stderr": "", "skipped": true,
       "msg": "Command would have run if not in check mode" }
```

O módulo hoje declara `supports_check_mode=True` e, sem `creates`/`removes`,
devolve `rc = 0` com saída vazia (`ansible/modules/command.py`). Ou seja: o
esquecimento deixou de falhar e passou a entregar um valor plausível e
**falso** — `rc = 0` é exatamente o código de "deu certo". Um
`when: media_blkid.rc == 0` passaria a concluir "o disco de mídia está
conectado" numa simulação em que o `blkid` nunca chegou a rodar.

*Princípio geral: um valor padrão que se parece com sucesso é mais perigoso
que um erro. O erro você conserta; o falso sucesso você acredita.*

### 4.5 Por que existem toggles de reversão

Cada endurecimento de segurança tem uma variável correspondente em
`group_vars`. Não é indecisão: é reconhecer que hardening pode causar
regressão, e que **poder reverter uma coisa por vez** é o que torna o
diagnóstico possível.

| Variável | Se quebrar | Reverter para |
|---|---|---|
| `jellyfin_privileged: false` | Transcodificação por hardware falha | `true` |
| `jellyfin_media_readonly: true` | Metadados não salvam junto à mídia | `false` |
| `media_bind_address: 127.0.0.1` | App de música na LAN não conecta | `0.0.0.0` |
| `filebrowser_bind_address: 127.0.0.1` | FileBrowser na LAN não conecta | `0.0.0.0` |
| `pelican_privileged: false` | Painel não sobe | `true` |
| `pelican_seccomp_unconfined: false` | Erro de syscall no PHP | `true` |
| `ttyd_bind_interface: lo` | `ssh.<domínio>` inacessível | `""` |
| `pelican_trusted_proxies` | Painel vê IP errado | `"*"` |

---

## 5. Mudanças de segurança

| Antes | Agora | Impacto |
|---|---|---|
| Senhas no compose, versionadas | `ansible-vault` + templates | Crítico |
| `ttyd` em `0.0.0.0` com login root | `-i lo`, só via Access | Crítico |
| `privileged: true` em dois containers | `group_add` + devices | Crítico |
| `no-new-privileges:false` | `:true` | Alto |
| `TRUSTED_PROXIES=*` | Faixas do Cloudflare | Alto |
| `cloudflared` como root | Usuário próprio + hardening systemd | Alto |
| `disable_gpg_check: true` | Chave GPG importada | Alto |
| `accept_hostkey: true` (TOFU cego) | Chave do GitHub fixada | Médio |
| Sem hardening de SSH | Sem root, sem senha, MaxAuthTries 3 | Alto |
| Chave SFTP do Wings em `0777` | `0600 root:root` | Crítico |
| Firewall só no host, fora do Git | Role declarativa | Alto |
| Redis sem senha | `--requirepass` do vault | Médio |
| Navidrome/Picard em `0.0.0.0` | `127.0.0.1` | Alto |
| Jellyfin com escrita em 1,8 TB | Montado `:ro` | Médio |

---

## 6. Bugs encontrados e corrigidos

Diagnosticados por auditoria do host em execução, não por leitura de código.

**`playit.service` — três defeitos numa unit de 20 linhas**
```ini
StartLimitIntervalSec:60      # dois-pontos: systemd descartava a linha inteira
Restart=always                # ...
Restart=on-failure            # declarado duas vezes; a segunda vencia calada
```
Além de `StartLimitIntervalSec` estar em `[Service]`, quando pertence a
`[Unit]`. O systemd registrava tudo isso em **todo boot**, no `dmesg`, e
ninguém lia.

**nginx — dois `server_name` idênticos**
`painel.conf` e `pelican.conf` declaravam o mesmo host. O nginx descartava um
e avisava `conflicting server name`. Qual sobrevivia dependia da ordem
alfabética do glob — comportamento acidental que ninguém escolheu.

**`BEGIND_PROXY` — erro de digitação que não gera erro**
Deveria ser `BEHIND_PROXY`. Como o nome não correspondia a nada, era
ignorado, e o painel nunca soube que estava atrás de um proxy. Bugs assim não
falham: produzem comportamento silenciosamente errado.

**`changed_when` lendo o stream errado**
`docker compose up` escreve progresso em **stderr**. A verificação lia
`stdout`, então a task nunca reportava `changed` — nem criando containers do
zero.

**`dnf autoremove` disfarçado de leitura**
Marcado com `changed_when: false`. Removia pacotes em produção enquanto o
relatório dizia "ok".

**`container_execmem` — boolean que não existe mais**
Removido na política 42.x do AlmaLinux 10. O playbook antigo tentaria aplicá-lo
e falharia. Booleans do SELinux dependem da versão da política; não são API
estável.

**Duas cópias do `cloudflared`**
Uma do RPM em `/usr/bin`, outra manual em `/usr/local/bin`. A unit apontava
para a manual — então `dnf update` atualizava um binário que não era o que
rodava, e o serviço ficou preso numa versão antiga indefinidamente.

**`secure_path` sem `/usr/local/bin`**
Durante a auditoria, `sudo command -v ttyd` dizia "não encontrado" com o
serviço rodando. Os binários existiam; não estavam no PATH do sudo. Quase
tirei a conclusão errada.

**FileBrowser — UID fixo da imagem, não derivado do host**
Diferente do Jellyfin (que aceita qualquer GID via `group_add`), a imagem
`filebrowser/filebrowser` roda com um UID/GID **fixos** seus (1000:1000,
`user` dentro da própria imagem — confirmado com
`docker run --entrypoint '' filebrowser/filebrowser id`). A primeira versão
da role forçava `--user {{ app_uid }}:{{ app_gid }}` para casar com o dono
dos diretórios no host. Em produção isso funciona por coincidência
(`app_uid` também é 1000 lá); no laboratório, onde `app_uid` é 1001, quebrou
com `cp: can't create '/config/settings.json': Permission denied` — o
processo perdia acesso ao `/config` que a própria imagem já é dona. Correção:
os diretórios montados (`database/` e a raiz de upload) ficam com dono
numérico `1000:1000` fixo em todo host, e nem o compose nem a inicialização
usam `{{ app_uid }}` para este serviço específico.

**`services.yml` não tolera o `cloudflared` pulado no laboratório**
`diag.yml` já tem uma exceção documentada para `cloudflared inactive` no
laboratório (túnel próprio ainda pendente — seção 8). `services.yml` não
tem: a task `Serviços systemd ativos e habilitados` falha a play inteira com
"Could not find the requested service" quando a unit não existe, porque
`--skip-tags cloudflared` no `setup.yml` nunca chega a criar essa unit.
Achado validando a stack do FileBrowser no laboratório em 12/09/2026; ainda
não corrigido — ver seção 8.

---

## 7. Incidente de credenciais

Uma auditoria do histórico Git encontrou um **token de API da Cloudflare
ativo** e as credenciais do túnel commitadas ao longo de todo o histórico,
além de senhas de MariaDB em texto claro.

**Causa raiz:** o `deploy.sh` original fazia `git add .` cego antes de cada
execução. Qualquer arquivo que caísse no diretório entrava no commit.

**Resposta:**
1. Reescrita do histórico com `git filter-repo`
2. Rotação do token da Cloudflare
3. `deploy.sh` reescrito: `git add -u` (só arquivos já rastreados) e varredura
   com `gitleaks` antes de commitar
4. `.gitignore` cobrindo `vault.yml`, `*.pem`, `*.json` de credencial
5. Migração de todos os segredos para `ansible-vault`

**Pendente:** as senhas do MariaDB continuam no histórico público. Trocá-las
no vault não basta — o banco já existe com a senha antiga e exige `ALTER USER`.
O procedimento está na seção 9.

Registro isto porque a resposta a incidente é parte do trabalho, e um
portfólio que só mostra o caminho feliz não diz nada sobre como a pessoa
reage quando algo dá errado.

---

## 8. Dívidas conhecidas

Aberto, não esquecido.

| Item | Por que ainda não foi resolvido |
|---|---|
| Jellyfin com `label:disable` | Precisa de política SELinux própria, como a do ttyd. O boolean que resolvia foi removido na política 42.x. |
| MariaDB 10.5 (sem suporte desde jun/2025) | Subir para 11.x LTS é **migração de dados**, não convergência de config. Exige backup e janela. |
| `NOPASSWD:ALL` para o usuário da aplicação | O `deploy.sh` roda desatendido. Separar usuário de automação do de aplicação é mudança de processo. |
| `Caddyfile` do Pelican não gerenciado | O arquivo original do host não foi capturado na auditoria. Sobrescrever com um deduzido é risco desnecessário. |
| Sem `update.yml` agendado | A auditoria achou 26 versões de kernel e correções *Important* de OpenSSH e nginx pendentes. Falta um `systemd timer`. |
| Sem monitoramento nem alerta | Próxima fase: Prometheus + node_exporter. |
| Sem rotina de backup testada | Existem dados em `/mnt/cloud`, mas sem restauração verificada não é backup. |
| `APP_URL` do painel fixo no compose | Contraria a regra de zero valor fixo fora de `group_vars` e impede testar o painel em qualquer nome que não seja o de produção — o Laravel gera URL absoluta e redireciona para lá. Vira variável quando o laboratório precisar do painel de verdade. |
| Chave de deploy do site não é gerenciada | O `setup.yml` já clona o site, mas a chave SSH privada do `app_user` é segredo que não está no vault nem no repositório. Hoje a task avisa e pula quando ela falta; automatizar exige decidir onde guardar mais um segredo. |
| `services.yml` falha inteiro se `cloudflared` for pulado no lab | A task de serviços systemd não tem `failed_when: false`/exceção como o `diag.yml` já tem para este caso conhecido. Corrigir exige decidir se a exceção é só para o grupo `lab` ou geral — não decidi sozinho, ver README seção 6. |
| Política de Cloudflare Access para `files.<domínio>` não é IaC | Mesma situação de `jellyfin`/`music`/`capas`: a rota de DNS é gerenciada pelo `cloudflared` CLI, mas a política de autenticação do Access em si é configurada manualmente no painel/CLI do Zero Trust, fora deste repositório. |

---

## 9. Rotação de segredos

As senhas antigas estão no histórico público. Trocar no vault não basta.

```bash
# 1. Backup ANTES de qualquer coisa
docker compose -f ~/docker/pelican-panel/docker-compose.yml stop
sudo tar czf ~/pelican-db-$(date +%F).tar.gz ~/docker/pelican-panel/var/lib/mysql

# 2. Suba só o banco e troque as senhas
docker compose up -d database
docker exec -it pelican-panel-database-1 mysql -uroot -p'SENHA_ANTIGA' -e "
  ALTER USER 'pelican'@'%' IDENTIFIED BY 'NOVA_SENHA';
  ALTER USER 'root'@'localhost' IDENTIFIED BY 'NOVA_ROOT';
  FLUSH PRIVILEGES;"

# 3. Grave as novas no vault e reaplique
ansible-vault edit group_vars/all/vault.yml
ansible-playbook playbooks/setup.yml --limit prod --tags gameserver --ask-vault-pass
ansible-playbook playbooks/services.yml --limit prod
```

---

## 10. Verificação de binários

`ttyd`, `playit` e `wings` são baixados do GitHub com **verificação SHA-256**.
O `get_url` aborta se o arquivo não bater — defesa contra comprometimento de
supply chain.

| Binário | Versão | SHA-256 (início) |
|---|---|---|
| ttyd | 1.7.7 | `8a217c968aba172e…` |
| playit | v1.0.5 | `217bd341b3ea88f9…` |
| wings | v1.0.0-beta25 | `4fb1f8302cb4458d…` |

Verificados contra o host em 08/09/2026: os três conferem, então o `get_url`
não baixa nada — a task é no-op.

Ao trocar de versão, recalcule (no shell, com a versão **literal** — `{{ }}`
é sintaxe do Ansible e o shell não expande):

```bash
curl -sL https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 | sha256sum
```

---

## 11. Roteiro de validação

Antes de aplicar em produção, valide no clone virtual:

1. `--check --diff` — leia cada mudança proposta
2. Aplique e confira o relatório de verificação no final
3. Rode de novo → deve dar `changed=0`
4. `services.yml`, depois `diag.yml` sem falhas
5. Reinicie a VM → rode `diag.yml` de novo; tudo deve subir sozinho
6. **Teste destrutivo:** reinstale o SO na VM e rode `setup.yml` +
   `services.yml`. É o cenário real que o projeto promete suportar.

Só então `--limit prod`.

---

## Licença

MIT — ver [LICENSE](LICENSE).

---

## Transparência sobre o uso de IA

Este projeto foi desenvolvido **com auxílio do Claude Opus 5 (Anthropic)**,
usado como ferramenta para acelerar o processo de aprendizado.

O que isso significa na prática:

- **A arquitetura, as decisões e o ambiente são meus.** O servidor, os
  serviços, os problemas encontrados e o que fazer com eles partiram de mim.
- **A IA foi usada como par de revisão e acelerador de estudo:** revisar
  código em busca de bugs, explicar conceitos de SELinux e systemd, redigir
  documentação e propor estruturas de código.
- **Tudo foi revisado, testado e validado por mim** contra o host real. Vários
  achados da IA estavam errados e foram corrigidos no processo — inclusive
  bugs que ela mesma introduziu e que só apareceram na revisão seguinte.
- **O objetivo é aprender, não terceirizar.** Cada arquivo tem comentários
  explicando *por que* a decisão foi tomada, justamente para que este
  repositório continue sendo material de estudo meu no futuro.

Considero essa transparência parte da disciplina profissional. Ferramentas
mudam; a capacidade de entender, questionar e validar o resultado é o que
permanece.
