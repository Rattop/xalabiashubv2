# XalabiasHub

**Infraestrutura como código para um homelab em produção, implementada em Ansible.**

![Ansible](https://img.shields.io/badge/Ansible-2.15%2B-EE0000?logo=ansible&logoColor=white)
![AlmaLinux](https://img.shields.io/badge/AlmaLinux-10.2-0F4266?logo=almalinux&logoColor=white)
![SELinux](https://img.shields.io/badge/SELinux-enforcing-success)
![Licença](https://img.shields.io/badge/licen%C3%A7a-MIT-blue)

---

## Visão geral

Este repositório descreve, de forma integral e versionada, a configuração de
um servidor doméstico em operação contínua: AlmaLinux 10 sobre hardware
bare-metal, executando serviços de mídia, um painel de servidores de jogo e
uma camada de entrada baseada em túnel reverso. O objetivo é que o host seja
reproduzível a partir do repositório, sem etapas manuais, sem segredos em
texto claro e sem configuração que exista apenas na máquina.

O hardware é um notebook de 2017 com processador Core i3 e 8 GB de memória.
A limitação é tratada como restrição de projeto: cada serviço acrescentado é
avaliado quanto ao consumo de memória e CPU, e decisões de arquitetura que
seriam indiferentes em hardware abundante — como a escolha de não hospedar a
própria stack de observabilidade — tornam-se determinantes.

A documentação registra tanto as decisões consolidadas quanto os defeitos
identificados ao longo do desenvolvimento. Esse registro é deliberado. Em
infraestrutura, a configuração final costuma ser menos instrutiva que o
percurso de diagnóstico que a produziu: um arquivo correto não explica por
que as alternativas foram descartadas, ao passo que o relato de uma falha
preserva o raciocínio e impede que o mesmo erro seja reintroduzido.

---

## 1. Arquitetura

### 1.1 Topologia

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
│                 ├─► ttyd :7681          (terminal web)            │
│                 └─► FileBrowser :8080   (transferência de arquivos)│
│                                                                   │
│   playit ──────────► servidores de jogo (TCP/UDP bruto)           │
│   wings ───────────► cria e destrói containers de jogo            │
│   tailscaled ──────► rede privada do mantenedor, independente     │
│                       do túnel Cloudflare acima                   │
│                                                                   │
│   firewalld: apenas 22 e 2022 acessíveis pela rede local          │
│   SELinux: enforcing, com política customizada para o ttyd        │
│                                                                   │
│   Armazenamento:  LVM/XFS (sistema)  ·  BTRFS 1,8 TB (mídia)      │
└───────────────────────────────────────────────────────────────────┘
```

### 1.2 Princípio de exposição

A decisão estruturante do projeto é a ausência de redirecionamento de portas
no roteador. Tanto o `cloudflared` quanto o `playit` estabelecem conexões de
**saída**, e o tráfego de entrada retorna por elas. Disso decorrem duas
consequências: não existe superfície exposta a varredura na internet, e o
firewall pode manter fechadas, inclusive para a rede local, as portas 80,
7681 e 8096 — quem as acessa é o túnel, a partir de `localhost`.

O `tailscaled`, introduzido posteriormente para acesso administrativo remoto,
observa o mesmo modelo: conecta de saída e recorre a NAT traversal e a relays
DERP, sem exigir porta redirecionada.

---

## 2. Estrutura do repositório

```
├── ansible.cfg              Configuração do Ansible (diff habilitado por padrão)
├── inventory.ini            Hosts: prod (bare-metal) e lab (clone virtual)
├── deploy.sh                Wrapper: simula, confirma, aplica
├── requirements.yml         Collections necessárias
│
├── group_vars/all/
│   ├── main.yml             Fonte única de verdade da configuração
│   └── vault.yml            Segredos cifrados (não versionado)
│
├── playbooks/
│   ├── setup.yml            Convergência completa do host
│   ├── services.yml         Garante serviços e stacks em execução
│   ├── update.yml           Manutenção: pacotes, imagens, limpeza
│   └── diag.yml             Diagnóstico somente leitura, com verificações
│
└── roles/
    ├── common/              Pacotes, usuário, sudo, endurecimento de SSH
    ├── tailscale/           Acesso remoto administrativo
    ├── storage/             Montagem BTRFS por edição cirúrgica do fstab
    ├── selinux/             Booleans e políticas locais
    ├── firewall/            firewalld declarativo
    ├── docker/              Engine e plugin compose
    ├── ingress/             nginx, cloudflared, ttyd
    ├── media/               Jellyfin, Navidrome
    ├── gameserver/          Pelican Panel, Wings, Playit
    └── filemanager/         FileBrowser
```

---

## 3. Requisitos

- Ansible Core 2.15 ou superior no nó de controle.
- Acesso SSH por chave ao host, com privilégio de escalonamento.
- Host baseado em Enterprise Linux 9 ou superior (AlmaLinux, Rocky, RHEL);
  as roles pressupõem `dnf`, `firewalld` e política SELinux *targeted*.
- Credencial do túnel Cloudflare, emitida fora deste repositório.

---

## 4. Utilização

### 4.1 Preparação inicial

```bash
ansible-galaxy collection install -r requirements.yml

cp group_vars/all/vault.yml.example group_vars/all/vault.yml
openssl rand -base64 24        # executar uma vez para cada segredo
ansible-vault encrypt group_vars/all/vault.yml
```

### 4.2 Execução

```bash
# 1. Simulação. Exibe o diff de cada arquivo sem alterar o host.
ansible-playbook playbooks/setup.yml --limit lab --check --diff --ask-vault-pass

# 2. Aplicação.
ansible-playbook playbooks/setup.yml --limit lab --ask-vault-pass

# 3. Verificação de idempotência: a segunda execução deve reportar changed=0.
ansible-playbook playbooks/setup.yml --limit lab --ask-vault-pass | tail -5
```

O script `./deploy.sh setup --limit lab` encapsula as três etapas e exige
confirmação explícita antes de aplicar.

### 4.3 Execução seletiva

```bash
ansible-playbook playbooks/setup.yml --tags nginx,docker    # apenas estas roles
ansible-playbook playbooks/setup.yml --skip-tags ssh        # tudo exceto esta
ansible-playbook playbooks/setup.yml --list-tasks           # inspeção prévia
```

### 4.4 Playbooks

| Playbook | Situação de uso |
|---|---|
| `setup.yml` | Host recém-instalado, ou correção de deriva de configuração |
| `services.yml` | Após reinicialização; restabelecimento do estado esperado |
| `update.yml` | Manutenção periódica |
| `diag.yml` | Diagnóstico após falha (somente leitura) |

---

## 5. Decisões de engenharia

### 5.1 O `fstab` não é substituído integralmente

Uma versão anterior do projeto copiava o arquivo inteiro
(`copy: src=files/fstab dest=/etc/fstab`), o que transferia os UUIDs de `/`,
`/boot` e `/home` da máquina de origem. Numa reinstalação — precisamente o
cenário que o projeto se propõe a suportar — o instalador cria partições com
UUIDs novos, e o arquivo copiado passaria a referenciar volumes inexistentes,
impedindo a inicialização do host.

Atualmente apenas as linhas relativas à mídia são gerenciadas, por meio do
módulo `ansible.posix.mount`, que edita o arquivo de forma cirúrgica.

*Princípio derivado: quando existe um módulo que compreende o **formato** do
arquivo, ele oferece garantias que a substituição integral não oferece.*

### 5.2 As políticas SELinux são versionadas como `.te`, não `.pp`

A resposta trivial a um bloqueio do SELinux consiste em desativá-lo. Adotou-se
o procedimento oposto para o `ttyd`: uma política de uma única linha, que
concede exatamente uma transição de processo.

A política é versionada em `.te` — código-fonte legível e auditável — e
compilada no próprio host. O formato `.pp`, por ser binário e dependente da
versão da política do sistema, degrada-se silenciosamente após atualizações.

O contraste é mantido de forma explícita: o Jellyfin ainda recorre a
`label:disable`, o que consta na seção de limitações em vez de ser omitido.

### 5.3 Os GIDs de vídeo são descobertos em tempo de execução

Para transcodificação por hardware, o Jellyfin requer acesso aos grupos
`render` e `video` do host. A formulação intuitiva — `group_add: [video,
render]` — não produz o efeito desejado, pois o Docker resolve nomes de grupo
**dentro** do container. A imagem do Jellyfin baseia-se em Debian, onde
`video` corresponde ao GID 44, enquanto no host AlmaLinux corresponde ao 39.
A divergência resultaria em negação silenciosa de acesso ao dispositivo.

A role obtém os identificadores numéricos por meio de `getent group` e os
injeta no arquivo de composição.

### 5.4 O modo de simulação exige tratamento explícito

Os módulos `command` e `shell` não executam o comando em modo `--check`, uma
vez que o Ansible não dispõe de meios para avaliar se um comando arbitrário é
seguro. A task é simplesmente omitida.

Por conseguinte, toda task cuja finalidade seja **coletar informação** para
condicionar outra recebe `check_mode: false`, acompanhado de
`changed_when: false`.

A justificativa dessa regra alterou-se ao longo do tempo, e tornou-se mais
grave. Originalmente, a variável registrada permanecia sem `.stdout` e sem
`.rc`, e seu uso produzia erro de atributo indefinido — falha imediata e
evidente. Verificação conduzida em 12/09/2026 contra o ansible-core 2.21.2
demonstra comportamento distinto:

```
TASK [comando] ***  skipping: [localhost]
"r": { "rc": 0, "stdout": "", "stderr": "", "skipped": true,
       "msg": "Command would have run if not in check mode" }
```

O módulo passou a declarar `supports_check_mode=True` e, na ausência de
`creates` ou `removes`, retorna `rc = 0` com saída vazia. A omissão deixou,
portanto, de falhar, passando a produzir um valor plausível e incorreto: `rc =
0` é o código convencional de êxito. Uma condição como
`when: media_blkid.rc == 0` concluiria que o disco de mídia está conectado em
uma simulação na qual o `blkid` sequer chegou a ser executado.

*Princípio derivado: um valor padrão que se assemelha a êxito é mais perigoso
que um erro. O erro é corrigido; o falso êxito é acreditado.*

### 5.5 Cada endurecimento dispõe de reversão individual

Toda alteração de segurança possui variável correspondente em `group_vars`.
A intenção não é indecisão, mas o reconhecimento de que endurecimento pode
provocar regressão, e de que a capacidade de reverter **um item por vez** é o
que torna o diagnóstico viável.

| Variável | Sintoma em caso de regressão | Valor de reversão |
|---|---|---|
| `jellyfin_privileged: false` | Falha na transcodificação por hardware | `true` |
| `jellyfin_media_readonly: true` | Metadados não são gravados junto à mídia | `false` |
| `media_bind_address: 127.0.0.1` | Cliente de música na rede local não conecta | `0.0.0.0` |
| `filebrowser_bind_address: 127.0.0.1` | FileBrowser inacessível na rede local | `0.0.0.0` |
| `pelican_privileged: false` | Painel não inicializa | `true` |
| `pelican_seccomp_unconfined: false` | Erro de chamada de sistema no PHP | `true` |
| `ttyd_bind_interface: lo` | `ssh.<domínio>` inacessível | `""` |
| `pelican_trusted_proxies` | Painel registra endereço de origem incorreto | `"*"` |

---

## 6. Postura de segurança

### 6.1 Alterações aplicadas

| Estado anterior | Estado atual | Severidade |
|---|---|---|
| Senhas em texto claro no compose versionado | `ansible-vault` e templates | Crítica |
| `ttyd` em `0.0.0.0` com sessão de root | `-i lo`, acesso mediado pelo Access | Crítica |
| `privileged: true` em dois containers | `group_add` e mapeamento de devices | Crítica |
| `no-new-privileges:false` | `:true` | Alta |
| `TRUSTED_PROXIES=*` | Faixas oficiais da Cloudflare | Alta |
| `cloudflared` executando como root | Usuário de serviço dedicado | Alta |
| `disable_gpg_check: true` | Chave GPG importada e fingerprint fixada | Alta |
| `accept_hostkey: true` (confiança na primeira conexão) | Chave do GitHub declarada previamente | Média |
| Ausência de endurecimento de SSH | Sem root, sem senha, `MaxAuthTries 3` | Alta |
| Chave SFTP do Wings com modo `0777` | `0600 root:root` | Crítica |
| Firewall configurado apenas no host, fora do versionamento | Role declarativa | Alta |
| Redis sem autenticação | `--requirepass` proveniente do vault | Média |
| Navidrome e Picard em `0.0.0.0` | `127.0.0.1` | Alta |
| Jellyfin com permissão de escrita sobre 1,8 TB | Montagem `:ro` | Média |

### 6.2 Verificação de integridade dos binários

Os binários de `ttyd`, `playit` e `wings` são obtidos do GitHub com
verificação de SHA-256. O módulo `get_url` interrompe a execução caso a soma
não corresponda, o que constitui defesa contra comprometimento da cadeia de
suprimento.

| Binário | Versão | SHA-256 (prefixo) |
|---|---|---|
| ttyd | 1.7.7 | `8a217c968aba172e…` |
| playit | v1.0.5 | `217bd341b3ea88f9…` |
| wings | v1.0.0-beta25 | `4fb1f8302cb4458d…` |

Conferidos contra o host em 08/09/2026. Uma vez que os arquivos locais
correspondem às somas esperadas, o `get_url` não realiza download e a task
comporta-se como no-op.

Ao alterar a versão, a soma deve ser recalculada no shell, com a versão
literal — `{{ }}` é sintaxe do Ansible e não é expandida pelo shell:

```bash
curl -sL https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 | sha256sum
```

---

## 7. Defeitos identificados e corrigidos

Os itens a seguir foram detectados por auditoria do host em execução e por
validação em ambiente de laboratório, não por leitura isolada do código.

**`playit.service` — três defeitos em uma unit de vinte linhas**

```ini
StartLimitIntervalSec:60      # dois-pontos: a linha era integralmente descartada
Restart=always                # ...
Restart=on-failure            # declarado duas vezes; a segunda declaração prevalecia
```

Além disso, `StartLimitIntervalSec` figurava em `[Service]`, quando pertence a
`[Unit]`. O systemd registrava as três ocorrências a cada inicialização, sem
que o registro fosse consultado.

**nginx — dois `server_name` idênticos**

Os arquivos `painel.conf` e `pelican.conf` declaravam o mesmo host. O nginx
descartava um deles e emitia `conflicting server name`. A escolha do
sobrevivente dependia da ordem alfabética de expansão do glob, caracterizando
comportamento acidental.

**`BEGIND_PROXY` — erro de digitação que não produz erro**

A variável correta é `BEHIND_PROXY`. Como o identificador grafado não
correspondia a nenhuma variável esperada pela aplicação, era ignorado, e o
painel permanecia sem conhecimento de operar atrás de um proxy. Defeitos dessa
natureza não falham: produzem comportamento silenciosamente incorreto.

**`changed_when` avaliando o fluxo incorreto**

O comando `docker compose up` escreve o progresso em **stderr**. A verificação
examinava `stdout`, de modo que a task nunca reportava `changed`, mesmo ao
criar containers do zero.

**`dnf autoremove` classificado como operação de leitura**

A task apresentava `changed_when: false`, o que fazia com que a remoção de
pacotes em produção fosse reportada como ausência de alteração.

**`container_execmem` — boolean inexistente na política vigente**

Removido na política 42.x do AlmaLinux 10. Sua aplicação resultaria em falha.
Booleans do SELinux dependem da versão da política e não constituem interface
estável.

**Duas instâncias do binário `cloudflared`**

Uma proveniente do RPM, em `/usr/bin`, e outra instalada manualmente em
`/usr/local/bin`. A unit referenciava a segunda, de modo que as atualizações
via `dnf` incidiam sobre um binário que não era o executado, mantendo o
serviço indefinidamente em versão antiga.

**`secure_path` sem `/usr/local/bin`**

Durante a auditoria, `sudo command -v ttyd` reportava ausência do binário com
o serviço em execução. Os binários existiam, mas não constavam do PATH
utilizado pelo sudo — situação que induziu a conclusão inicial equivocada.

**FileBrowser — identificador de usuário fixo na imagem**

Diferentemente do Jellyfin, que aceita qualquer GID por meio de `group_add`, a
imagem `filebrowser/filebrowser` executa com UID e GID fixos (1000:1000),
verificáveis por `docker run --entrypoint '' filebrowser/filebrowser id`. A
primeira versão da role forçava `--user {{ app_uid }}:{{ app_gid }}` para
compatibilizar com o proprietário dos diretórios no host. Em produção o
procedimento funciona por coincidência, pois `app_uid` também equivale a 1000;
no laboratório, onde corresponde a 1001, a inicialização falhou com
`cp: can't create '/config/settings.json': Permission denied`, uma vez que o
processo perdia acesso ao diretório de que a própria imagem é proprietária.
Adotou-se, como correção, a atribuição do proprietário numérico `1000:1000` aos
diretórios montados, independentemente do host.

**`capas.<domínio>` expunha sessão gráfica sem autenticação**

Medição externa conduzida durante a convergência de produção de 12/09/2026
constatou que `jellyfin`, `music` e `painel` respondiam `302` — redirecionamento
para a autenticação do Cloudflare Access —, enquanto `capas` respondia `200`,
alcançando diretamente a origem. O conteúdo servido era a interface noVNC do
Picard, distribuída pela imagem com `WEB_AUTHENTICATION=0` e `VNC_PASSWORD`
vazio: sessão gráfica interativa, desprovida de autenticação, com permissão de
escrita sobre a totalidade da biblioteca de música.

A rota constava de `cloudflare_ingress` desde antes da criação deste
repositório. A vinculação do serviço a `127.0.0.1`, aplicada na mesma
convergência, restringiu apenas o acesso pela rede local; o caminho através do
túnel permanecia aberto. Optou-se pela remoção do serviço, e não por sua
proteção, dado que se encontrava em desuso.

*Lição derivada: o inventário de rotas do túnel deve ser revisado
conjuntamente com o inventário de serviços. Uma rota remanescente não
desaparece do mapa de exposição — apenas deixa de ser observada.*

**Exposição de segredos pela saída do playbook**

O `ansible.cfg` do projeto habilita `diff` por padrão, decisão adequada para
revisão de alterações. Constatou-se, porém, que a aplicação de `--diff` sobre
um `template:` imprime o arquivo renderizado integralmente — incluindo, no caso
do compose do Pelican, três senhas provenientes do vault. O `ansible-vault`
protege o segredo em repouso, no versionamento; não protege sua transmissão
pela saída do playbook. A proteção correspondente é `no_log: true`, declarada
explicitamente em cada task que renderize segredo.

---

## 8. Incidente de credenciais

Auditoria do histórico de versionamento identificou um token de API da
Cloudflare ativo, credenciais do túnel e senhas de MariaDB em texto claro,
presentes ao longo de todo o histórico.

**Causa raiz.** O `deploy.sh` original executava `git add .` de forma
indiscriminada antes de cada execução, de modo que qualquer arquivo presente
no diretório era incorporado ao commit.

**Medidas adotadas.**

1. Reescrita do histórico com `git filter-repo`.
2. Rotação do token da Cloudflare.
3. Reescrita do `deploy.sh`, que passou a utilizar `git add -u` — restrito a
   arquivos já rastreados — e a executar varredura com `gitleaks` previamente
   ao commit.
4. Ampliação do `.gitignore` para `vault.yml`, `*.pem` e arquivos de
   credencial em formato JSON.
5. Migração integral dos segredos para `ansible-vault`.

**Rotação das senhas de banco.** As credenciais do MariaDB foram rotacionadas
em 12/09/2026, conforme o procedimento da seção 10. Registram-se dois achados
não evidentes: a senha anterior do usuário `root` não coincidia com a do
usuário da aplicação, e existiam **duas** contas de root (`root@localhost` e
`root@%`), de modo que a rotação de apenas uma delas preservaria uma conta
privilegiada com credencial comprometida.

---

## 9. Limitações conhecidas

| Item | Justificativa da pendência |
|---|---|
| Jellyfin com `label:disable` | Requer política SELinux própria, nos moldes da adotada para o ttyd. O boolean que resolvia a questão foi removido na política 42.x. |
| MariaDB 10.5, sem suporte desde jun/2025 | A migração para 11.x LTS constitui migração de dados, não convergência de configuração. Exige backup e janela de manutenção. |
| `NOPASSWD:ALL` para o usuário da aplicação | O `deploy.sh` executa de forma desatendida. A segregação entre usuário de automação e de aplicação configura mudança de processo. |
| `Caddyfile` do Pelican não gerenciado | O conteúdo original do host não foi capturado na auditoria inicial. Substituí-lo por versão deduzida representaria risco desnecessário. |
| Ausência de agendamento do `update.yml` | A auditoria identificou 26 versões de kernel e correções classificadas como *Important* pendentes. Falta um `systemd timer`. |
| Configuração do painel Pelican em volume anônimo | O arquivo `.env`, que contém a `APP_KEY`, reside em volume Docker anônimo. Um `docker compose down -v` o destruiria de forma irrecuperável, inutilizando os valores cifrados no banco. A correção consiste em migrar para bind mount explícito. |
| Ausência de rotina de backup verificada | Existem dados em `/mnt/cloud`, porém, sem restauração testada, não se caracteriza backup. |
| `APP_URL` do painel fixo no compose | Contraria a regra de ausência de valores literais fora de `group_vars` e impede o teste do painel sob qualquer nome distinto do de produção, dado que o Laravel gera URLs absolutas. |
| Chave de deploy do site não gerenciada | A chave privada do `app_user` não consta do vault nem do repositório. A task emite aviso e é omitida quando ausente; automatizá-la exige decidir o local de custódia de mais um segredo. |
| `services.yml` falha integralmente quando `cloudflared` é omitido no laboratório | A task de serviços systemd não dispõe da exceção que o `diag.yml` já implementa para esse caso conhecido. |
| Idempotência de `var/lib/mysql` | A role atribui `1000:1000` ao diretório, enquanto o entrypoint da imagem o reatribui a 999 a cada inicialização. A task reporta `changed` permanentemente, o que compromete o critério de verificação adotado no projeto. |
| Avisos de depreciação do ansible-core | `DEFAULT_MANAGED_STR` e `INJECT_FACTS_AS_VARS` serão removidos nas versões 2.23 e 2.24, respectivamente. A migração para `ansible_facts[...]` está pendente. |
| `files.<domínio>` sem política de Cloudflare Access | Medição de 12/09/2026: o hostname alcança a origem sem autenticação de borda. Trata-se de serviço com permissão de escrita e exclusão, cuja única barreira seria a autenticação própria. A política é configurada no Zero Trust, fora deste repositório. |

---

## 10. Rotação de segredos

Credenciais expostas no histórico exigem rotação efetiva; a substituição do
valor no vault é insuficiente, pois não altera contas já existentes no banco.

```bash
# 1. Backup previamente a qualquer alteração
docker compose -f ~/docker/pelican-panel/docker-compose.yml stop
sudo tar czf ~/pelican-db-$(date +%F).tar.gz ~/docker/pelican-panel/var/lib/mysql

# 2. Enumerar as contas existentes antes de decidir o que alterar
#    (no MariaDB 10.4+ a tabela é global_priv; mysql.user é view)
docker exec pelican-panel-database-1 \
  mysql -uroot -p'SENHA_ANTIGA' -N -e \
  "SELECT CONCAT(user,0x40,host) FROM mysql.global_priv;"

# 3. Aplicar a rotação a todas as contas pertinentes
docker exec -it pelican-panel-database-1 mysql -uroot -p'SENHA_ANTIGA' -e "
  ALTER USER 'pelican'@'%'        IDENTIFIED BY 'NOVA_SENHA';
  ALTER USER 'root'@'localhost'   IDENTIFIED BY 'NOVA_ROOT';
  ALTER USER 'root'@'%'           IDENTIFIED BY 'NOVA_ROOT';
  FLUSH PRIVILEGES;"

# 4. Registrar os novos valores no vault e reaplicar
ansible-vault edit group_vars/all/vault.yml
ansible-playbook playbooks/setup.yml --limit prod --tags gameserver --ask-vault-pass
ansible-playbook playbooks/services.yml --limit prod --ask-vault-pass
```

Observa-se que, entre a etapa 3 e a recriação dos containers, a aplicação
permanece com a credencial anterior em memória e não estabelece novas conexões
com o banco. As duas etapas devem, portanto, ser executadas em sequência
imediata.

---

## 11. Roteiro de validação

A aplicação em produção é precedida de validação no clone virtual:

1. Executar com `--check --diff` e examinar cada alteração proposta.
2. Aplicar e examinar o relatório de verificação emitido ao final.
3. Repetir a execução; espera-se `changed=0`.
4. Executar `services.yml` e, em seguida, `diag.yml`, sem falhas.
5. Reinicializar a máquina e executar `diag.yml` novamente; todos os serviços
   devem restabelecer-se automaticamente.
6. **Teste destrutivo:** reinstalar o sistema operacional na máquina virtual e
   executar `setup.yml` seguido de `services.yml`, reproduzindo o cenário que o
   projeto se propõe a suportar.

Somente após a conclusão dessas etapas aplica-se `--limit prod`.

---

## 12. Observabilidade

A camada de observabilidade encontra-se em fase de planejamento; a arquitetura
acordada está descrita em [`MONITORAMENTO.md`](MONITORAMENTO.md).

A decisão estruturante consiste em não hospedar a stack de monitoramento no
host monitorado. Uma instalação local de Prometheus e Alertmanager falharia
precisamente no cenário de maior relevância — a indisponibilidade do host —,
uma vez que o componente responsável pela notificação cessaria junto com o
objeto observado. Adota-se, por conseguinte, um agente de coleta local
(Grafana Alloy) que transmite as amostras, por conexão de saída, a um backend
externo responsável pelo armazenamento, pela avaliação das regras e pela
notificação.

---

## Licença

Distribuído sob a licença MIT. Ver [LICENSE](LICENSE).

---

## Nota metodológica sobre o uso de ferramentas de IA

O desenvolvimento deste repositório contou com assistência de modelos de
linguagem (Claude, Anthropic), empregados em revisão de código, redação de
documentação, explicação de conceitos de SELinux e systemd e proposição de
estruturas de código.

A arquitetura, as decisões de projeto e o ambiente são de responsabilidade do
mantenedor. Toda saída produzida com assistência foi verificada contra o host
em execução; parte dela mostrou-se incorreta e foi corrigida no processo,
incluindo defeitos introduzidos pela própria ferramenta e identificados em
revisão subsequente.

O registro consta por considerar-se que a origem do código é informação
pertinente à sua avaliação técnica.
