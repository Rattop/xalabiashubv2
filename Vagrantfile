# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# =============================================================================
# Vagrantfile — laboratório de testes do XalabiasHub
# =============================================================================
#
# O QUE ISTO CRIA
#   Uma VM AlmaLinux 10 sob KVM/libvirt, preparada para receber exatamente os
#   mesmos playbooks que rodam em produção. A ideia não é ter "uma VM Linux
#   qualquer" — é ter um alvo o mais parecido possível com o servidor real,
#   para que "funcionou no laboratório" signifique alguma coisa.
#
# POR QUE NÃO USO IP ESTÁTICO
#   A box oficial almalinux/10 tem um bug conhecido: `private_network` com IP
#   fixo falha dentro do NetworkManager da VM ("Connection activation failed").
#   Em vez de brigar com isso, a VM sobe com DHCP na rede de gerência padrão do
#   libvirt, e o IP é descoberto DEPOIS do boot (instruções no final deste
#   arquivo). Uma linha a mais de trabalho manual, mas zero tempo perdido
#   depurando um bug de terceiro que já está documentado.
#
# POR QUE O USUÁRIO 'vagrant' MUDA DE UID
#   group_vars/all/main.yml fixa app_uid: 1000 para o usuário 'ratto' — os
#   containers montam volumes esperando esse número exato. Só que a imagem
#   cloud do AlmaLinux já cria o usuário 'vagrant' com UID 1000. Se o playbook
#   tentasse criar 'ratto' também em 1000, a task falharia por UID duplicado.
#
#   A correção acontece ANTES de qualquer Ansible rodar: o provisionamento
#   desta VM desloca 'vagrant' para o UID 1500 (mantendo Vagrant plenamente
#   funcional — ele identifica o usuário pelo NOME, não pelo número) e libera
#   o 1000 para o 'ratto', criado aqui com sudo idêntico ao de produção.
#
# COMO USAR
#   vagrant up                     # sobe a VM (baixa a box na 1ª vez)
#   vagrant ssh-config             # confirma o usuário/porta de conexão
#   virsh net-dhcp-leases vagrant-libvirt   # descobre o IP atribuído
#   # cole o IP encontrado em inventory.ini, grupo [lab]
#   ansible-playbook playbooks/setup.yml --limit lab --check --diff --ask-vault-pass
# =============================================================================

Vagrant.configure("2") do |config|

  # ---------------------------------------------------------------------------
  # Box e identidade
  # ---------------------------------------------------------------------------
  config.vm.box = "almalinux/10"
  config.vm.hostname = "server-lab"

  # Não usamos pasta sincronizada: o Ansible conecta por SSH normalmente, como
  # faria contra o host real. Deixar isto ligado exigiria plugins extras
  # (virtiofs/NFS) sem trazer benefício nenhum para este caso de uso.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ---------------------------------------------------------------------------
  # Provider: libvirt/KVM
  # ---------------------------------------------------------------------------
  config.vm.provider :libvirt do |lv|
    lv.driver = "kvm"
    lv.cpu_mode = "host-passthrough"   # melhor desempenho: expõe a CPU real

    # O hardware de produção é um Core i3-7100U (2 núcleos / 4 threads) com
    # 8 GB de RAM. Os valores abaixo mantêm a MESMA ORDEM DE GRANDEZA — o
    # objetivo de um laboratório fiel é encontrar problemas de recurso antes
    # da produção, não fingir que existe hardware ilimitado.
    #
    # Ajuste para cima se a workstation tiver folga; nunca para muito além do
    # hardware real, ou o teste deixa de significar algo.
    lv.cpus   = 4
    lv.memory = 4096

    lv.disk_bus = "virtio"
    lv.nic_model_type = "virtio"

    # 40 GB cobre o sistema, as imagens Docker e um banco de testes. A mídia
    # de 1,8 TB do host real não faz sentido replicar aqui — o objetivo deste
    # laboratório é validar CONFIGURAÇÃO, não armazenar dados de verdade.
    lv.machine_virtual_size = 40
  end

  # ---------------------------------------------------------------------------
  # Provisionamento — roda uma vez, na primeira "vagrant up"
  # (rodar de novo com `vagrant provision` se precisar refazer manualmente)
  # ---------------------------------------------------------------------------

  # 1) Injeta a chave pública do HOST (a sua workstation) na VM.
  #    Substitui o `ssh-copy-id` manual: como este provisionador roda como
  #    root, dentro da própria VM, ele não depende de autenticação por senha
  #    (que o playbook de produção desativa de qualquer forma).
  pubkey_path = [
    File.expand_path("~/.ssh/id_ed25519.pub"),
    File.expand_path("~/.ssh/id_rsa.pub")
  ].find { |p| File.exist?(p) }

  if pubkey_path
    config.vm.provision "file",
      source: pubkey_path,
      destination: "/tmp/workstation_key.pub"
  else
    warn "AVISO: nenhuma chave pública encontrada em ~/.ssh/. " \
         "Gere uma com `ssh-keygen -t ed25519` antes de rodar o Ansible."
  end

  # 2) Prepara o usuário 'ratto' com sudo idêntico ao de produção e autoriza
  #    a chave copiada no passo anterior.
  #
  #    NOTA SOBRE O UID: em produção, 'ratto' é uid 1000 (group_vars/all).
  #    Nesta VM, uid 1000 já pertence ao usuário 'vagrant' — e não dá para
  #    renumerar um usuário com processo ativo: é justamente a sessão SSH
  #    que o próprio Vagrant usa para RODAR este script. O kernel recusa
  #    `usermod` em qualquer usuário logado, por design (evita invalidar uma
  #    sessão em andamento pela metade).
  #
  #    Matar essa sessão para liberar o UID e depois reconectar é possível,
  #    mas frágil dentro de um script de provisionamento. Em vez de lutar
  #    contra isso, o 'ratto' do laboratório nasce em uid 1001, e
  #    group_vars/lab/main.yml sobrescreve app_uid/app_gid SÓ para hosts
  #    deste grupo. group_vars/all continua descrevendo a verdade de
  #    produção; o laboratório documenta sua própria exceção, em vez de
  #    fingir ser idêntico num detalhe que não muda o resultado do teste.
  config.vm.provision "shell", name: "bootstrap-ratto", inline: <<-SHELL
    set -euo pipefail

    if id ratto &>/dev/null; then
      echo "==> usuário ratto já existe, pulando criação"
    else
      echo "==> criando usuário ratto (uid/gid 1001 — 1000 já é do 'vagrant')"
      groupadd -g 1001 ratto
      useradd  -u 1001 -g 1001 -m -s /bin/bash ratto

      echo "==> concedendo sudo idêntico ao de produção"
      echo "ratto ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ratto
      chmod 440 /etc/sudoers.d/ratto
    fi

    if [ -f /tmp/workstation_key.pub ]; then
      echo "==> autorizando a chave da workstation para o usuário ratto"
      install -d -m 0700 -o ratto -g ratto /home/ratto/.ssh
      cat /tmp/workstation_key.pub >> /home/ratto/.ssh/authorized_keys
      sort -u -o /home/ratto/.ssh/authorized_keys /home/ratto/.ssh/authorized_keys
      chown ratto:ratto /home/ratto/.ssh/authorized_keys
      chmod 600 /home/ratto/.ssh/authorized_keys
      rm -f /tmp/workstation_key.pub
    fi

    echo "==> pronto. Descubra o IP com:"
    echo "    virsh net-dhcp-leases vagrant-libvirt"
  SHELL
end
