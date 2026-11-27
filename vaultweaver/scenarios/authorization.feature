Feature: Autorização de acesso ao Vault

  Scenario: Desenvolvedor solicita uma policy autorizada
    Given que existe um VaultPolicyGrant para o namespace "payments"
    And que o Grant permite a policy "payments-read"
    And que existe um VaultKubernetesRoleBinding solicitando "payments-read"
    When o Vaultweaver reconcilia o recurso
    Then a associação deve ser considerada autorizada

  Scenario: Namespace sem VaultPolicyGrant
    Given que exista um VaultKubernetesRoleBinding no namepspace "payments"
    And nao exista um VaultPolicyGrant dando permissao para o namespace "payments"
    When o Vaultweaver reconcilia o recurso
    Then nenhuma role deve ser criada no Vault
    And o status do CR deve ser marcado com Ready=False
    And o reason do CR deve ser marcado com "GrantNotFound"

  Scenario: Desenvolvedor solicita uma policy não autorizada
    Given exista um VaultPolicyGrant para o namespace payments
    And e solicitado a criacao para o payments-admin
    And e autorizado somente payments-read
    When o Vaultweaver reconcilia o recurso
    Then o status do CR deve ser atualizado com o Ready=False
    And o reason do CR deve ser marcado com "PolicyNotAuthorized"

  Scenario: Plataforma revoga uma policy previamente autorizada
    Given Existe uma VaultPolicyGrant autorizando payments-read e payments-write
    And Existe uma VaultKubernetesRoleBinding solicitando payments-write e payments-read
    And Existe uma role no Vault associada a aplicacao payments-api, utilizandp ambas as policies
    When A equipe de plataforma atualiza o Grant e remove payments-write
    Then a role "payments-api" no Vault não deve mais conter a policy "payments-write"
    And a role "payments-api" deve continuar associada à policy "payments-read"
    And o status do CR deve ser atualizado como Ready=False
    And o reason do CR deve ser marcado como "PolicyNotAuthorized"
