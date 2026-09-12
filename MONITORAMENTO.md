# Observabilidade — documento de planejamento

> **Status:** provisório. Este documento descreve a arquitetura acordada para
> a camada de observabilidade, ainda não implementada. Quando a role
> correspondente existir e for validada, o conteúdo relevante migra para o
> `README.md` e para os comentários das próprias tasks, e este arquivo é
> removido.
>
> Última revisão: 12/09/2026.

---

## 1. Objetivo

Instrumentar o host de produção com coleta contínua de métricas e um canal de
alerta capaz de notificar falhas sem depender da disponibilidade do próprio
host. Até o momento, o único mecanismo de diagnóstico é o `diag.yml`, que é
sob demanda: ele responde "como está agora", mas não observa nada enquanto
ninguém o executa.

## 2. Princípio norteador

**O componente que emite o alerta não pode residir na máquina que ele
monitora.** Uma stack Prometheus + Alertmanager instalada no próprio servidor
falha precisamente no cenário mais importante — o host indisponível —, porque
o alertador morre junto com o objeto monitorado.

Essa restrição é o que determina toda a arquitetura abaixo: no host roda
apenas o agente de coleta; armazenamento, avaliação de regras e notificação
são externos.

## 3. Arquitetura

```
┌─ Host (AlmaLinux 10) ─────────────────┐          ┌─ Grafana Cloud (SaaS) ──────┐
│                                        │          │                              │
│  Grafana Alloy                         │  HTTPS   │  Mimir        (métricas)     │
│    ├── node exporter   (host)          │ ───────► │  Alerting     (regras)       │
│    ├── cAdvisor        (containers)    │  saída   │  Contact points              │
│    └── scrape cloudflared (túnel)      │          │  Grafana      (dashboards)   │
└────────────────────────────────────────┘          └──────────────┬───────────────┘
                                                                    │
                                                                    ▼
                                                             ntfy (push no celular)
```

O agente estabelece conexão de **saída** por HTTPS e empurra as amostras via
`remote_write`. Nenhuma porta é aberta no host nem no roteador, o que mantém
a coerência com as duas outras conexões externas já existentes no projeto — o
`cloudflared` e o `tailscaled` seguem exatamente o mesmo modelo.

## 4. Componentes e justificativa

| Componente | Escolha | Justificativa |
|---|---|---|
| Agente | **Grafana Alloy** | Sucessor do Grafana Agent, que se encontra em fim de vida. Binário único, distribuído em RPM assinado, com os *exporters* de host e de containers embutidos — dispensa instalar `node_exporter` e `cAdvisor` como processos ou containers separados. |
| Backend | **Grafana Cloud** (free tier) | Satisfaz o princípio da seção 2 sem infraestrutura adicional. Inclui armazenamento, motor de alertas e dashboards. Evita crescimento de série temporal num disco que já opera próximo da capacidade. |
| Notificação | **ntfy** | Não exige conta, número de telefone ou verificação. Aplicativo disponível para Android e iOS. A integração ocorre por requisição HTTP simples, configurável como *contact point* do tipo webhook. |

### 4.1 Alternativas descartadas

- **Stack local (Prometheus + Alertmanager + Grafana):** rejeitada pelo
  princípio da seção 2 e pelo custo de memória (aproximadamente 0,5–1 GB num
  host de 8 GB que já executa transcodificação de vídeo).
- **Telegram:** descartado por preferência do mantenedor.
- **WhatsApp via API oficial da Meta:** mensagens proativas exigem *templates*
  submetidos a aprovação prévia, o que introduz latência de processo
  incompatível com alertas operacionais.
- **WhatsApp via serviços não oficiais:** dependem de intermediários sem
  vínculo com a Meta, sujeitos a interrupção sem aviso.

## 5. Escopo de coleta

- **Host:** CPU, memória, swap, carga, espaço e inodes por sistema de arquivos,
  tráfego de rede.
- **Unidades systemd:** estado de `docker`, `nginx`, `cloudflared`, `ttyd`,
  `playit`, `wings` e `tailscaled`, via coletor `systemd` do node exporter.
- **Containers:** CPU, memória e contagem de reinícios, via cAdvisor.
- **Túnel:** o `cloudflared` expõe métricas próprias sobre o estado das
  conexões com a borda da Cloudflare.

Logs **não** são enviados nesta fase. A justificativa está na seção 8.

## 6. Regras de alerta previstas

| Condição | Severidade | Observação |
|---|---|---|
| Ausência de métricas por mais de 5 minutos | crítica | Detecta indisponibilidade do host. É o alerta que motiva toda a arquitetura. |
| Unidade systemd inativa | alta | Cobre queda de túnel, daemon de jogos e proxy reverso. |
| Container em ciclo de reinício | alta | Sintoma observado no `wings` durante a convergência de 12/09/2026. |
| Uso de `/` acima de 85% | média | A raiz dispõe de folga; o limiar é preventivo. |
| Crescimento de `/mnt/media` e `/mnt/cloud` | média | Ambos operam em 95,9%. Um limiar absoluto produziria alerta permanente; monitora-se, portanto, a **taxa de variação**, não o valor absoluto. |
| Pressão de memória ou uso de swap | média | 8 GB de RAM com transcodificação por hardware. |

A saúde SMART dos discos permanece a cargo do `diag.yml`: o Alloy não coleta
esse dado nativamente, e adicioná-lo exigiria um coletor adicional cujo custo
não se justifica nesta fase.

## 7. Restrição de cardinalidade

O plano gratuito admite 10.000 séries ativas. Dois pontos exigem atenção
desde a primeira versão do template:

1. O cAdvisor expõe, por padrão, métricas segmentadas por núcleo de CPU e por
   dispositivo de bloco. Essa segmentação costuma responder pela maior parte
   do consumo da cota e será descartada por `relabeling`.
2. O Wings cria e destrói containers de servidores de jogo com nomes no
   formato UUID. Cada instância nova origina um conjunto próprio de séries.
   Com o volume atual — dois servidores — o efeito é desprezível, mas o
   crescimento é monotônico e deve ser reavaliado periodicamente.

## 8. Segredos e superfície de vazamento

Dois valores são sensíveis e residem no `ansible-vault`:

| Variável | Natureza |
|---|---|
| `vault_grafana_cloud_token` | Credencial de escrita no endpoint de métricas. Deve ser emitida com escopo mínimo (`metrics:write`). |
| `vault_ntfy_topic` | O nome do tópico **é** a credencial: qualquer agente que o conheça pode publicar e qualquer cliente que o conheça pode ler. Equivale a uma URL de webhook secreta e, por isso, não é versionado. |

A task que renderiza o template de configuração leva `no_log: true`. Essa
decisão não é preventiva no abstrato: em 12/09/2026, a saída de um `--diff`
sobre um template equivalente expôs três senhas de banco de dados no terminal
(ver `README.md`, seção de defeitos). O `ansible-vault` protege o segredo em
repouso; apenas o `no_log` o protege em trânsito pela saída do playbook.

**Logs não são enviados** pelo mesmo motivo. Caso o journald estivesse sendo
replicado para um backend externo naquela data, as senhas expostas no terminal
teriam sido transmitidas junto. Se o envio de logs vier a ser adotado, deve
restringir-se a unidades específicas, nunca ao journal integral.

## 9. Fronteira do que é gerenciado por Ansible

Mantém-se a convenção já adotada para as políticas de Cloudflare Access:
configuração que reside dentro de um serviço de terceiros não é provisionada
por este repositório, mas é documentada nele.

- **Gerenciado:** instalação e configuração do Alloy no host.
- **Não gerenciado (manual, documentado):** regras de alerta, *contact points*
  e dashboards, todos definidos na interface da Grafana Cloud.

## 10. Estrutura prevista

```
roles/monitoring/
├── tasks/main.yml           chave GPG + repositório + pacote + serviço
└── templates/
    └── config.alloy.j2      remote_write, exporters e relabeling
```

Alterações complementares:

- `group_vars/all/main.yml`: `grafana_cloud_prometheus_url` e
  `grafana_cloud_instance_id` (não sensíveis); inclusão de `alloy` em
  `systemd_services`, o que automaticamente estende a cobertura do
  `services.yml` e do `diag.yml` ao novo serviço.
- `group_vars/all/vault.yml.example`: as duas variáveis da seção 8.
- `playbooks/setup.yml`: a role ao final da lista.

Não se prevê alteração em `firewall` nem em `selinux`. A comunicação é
exclusivamente de saída, e eventual restrição de SELinux — o ponto mais
provável é a leitura de `/var/run/docker.sock` pelo cAdvisor — será tratada
apenas se `ausearch` registrar negação efetiva, conforme o método de
investigação adotado no projeto.

## 11. Roteiro de validação

Aplica-se o roteiro geral do `README.md`, com duas verificações específicas:

1. Aplicar a role no laboratório e confirmar que o serviço `alloy` converge e
   é idempotente.
2. Confirmar, no *Explore* da Grafana Cloud, a chegada de amostras rotuladas
   com o ambiente correto.
3. Disparar um alerta de teste e confirmar a entrega no dispositivo móvel.
4. Somente então aplicar em produção.

Prevê-se a necessidade de distinguir as séries de laboratório das de produção
por meio de um rótulo `environment`, evitando que dados do clone virtual
contaminem as regras de alerta do host real.

## 12. Pré-requisitos pendentes

Ações a cargo do mantenedor, anteriores à implementação:

1. Criar a stack na Grafana Cloud e emitir credenciais de `remote_write` com
   escopo mínimo. Os valores não sensíveis (URL do endpoint e identificador da
   instância) entram em `group_vars`; o token vai para o vault.
2. Instalar o aplicativo ntfy no dispositivo móvel.
3. Definir o nome do tópico, preferencialmente com sufixo aleatório de
   entropia suficiente, e registrá-lo no vault.
