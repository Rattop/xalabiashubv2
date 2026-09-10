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

roles/common/     usuário, sudo, pacotes, hardening SSH
roles/storage/    montagem BTRFS cirúrgica (nunca sobrescreve fstab inteiro)
roles/docker/     engine + plugin compose
roles/selinux/    booleans de container + política customizada do ttyd
roles/firewall/   firewalld declarativo
roles/ingress/    nginx, cloudflared, ttyd
roles/media/      Jellyfin, Navidrome, Picard
roles/gameserver/ Pelican Panel, Wings, Playit

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
  `check_mode: false` + `changed_when: false`.** Sem isso, `--check`
  quebra com erro de atributo indefinido, porque esses módulos são
  pulados em simulação e a variável registrada fica sem `.stdout`/`.rc`.
  Veja `roles/storage/tasks/main.yml` para o padrão de referência e o
  comentário completo explicando o porquê.
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
