# Vaultweaver — System Design

## 1. Overview

O Vaultweaver é um Kubernetes Operator desenvolvido em Go, utilizando Kubebuilder e controller-runtime, com o objetivo de gerenciar declarativamente a integração entre aplicações Kubernetes e HashiCorp Vault.

O projeto permite que equipes de desenvolvimento solicitem acesso ao Vault através de Custom Resources, respeitando os limites de autorização definidos pela equipe de plataforma.

### Objetivos

- Permitir self-service para configuração de acesso ao Vault.
- Centralizar a governança das políticas de autorização.
- Reduzir configurações manuais de Kubernetes Auth Roles.
- Garantir isolamento entre aplicações, namespaces e clusters.
- Reconciliar continuamente o estado desejado com o estado no Vault.
- Impedir que recursos sejam modificados ou excluídos sem ownership comprovado.

### Fora do escopo do MVP

- Suporte a múltiplos servidores Vault por instalação.
- Adoção automática de recursos preexistentes.
- Criação livre de ACL Policies pelos desenvolvedores.
- Revogação ativa dos tokens já emitidos.
- Gerenciamento de ServiceAccounts em clusters remotos.

---

## 2. Architecture Overview

### Topologia

A arquitetura utiliza um único HashiCorp Vault compartilhado entre múltiplos clusters Kubernetes.

Cada cluster possui sua própria instalação do Vaultweaver e um Kubernetes Auth Mount exclusivo.

```text
              HashiCorp Vault
             (Shared Instance)
                     |
          +----------+----------+
          |                     |
     Auth Mount A          Auth Mount B
          |                     |
    Vaultweaver A          Vaultweaver B
          |                     |
    Kubernetes A           Kubernetes B
          |                     |
     Applications           Applications
```

### Responsabilidades

**Platform Team**
- Gerenciar Vault ACL Policies.
- Definir limites de acesso para cada namespace.
- Administrar os recursos de autorização.
- Configurar identidades e permissões dos Operators no Vault.
- Executar revogações emergenciais de tokens, quando necessário.

**Development Teams**
- Declarar necessidades de acesso por meio de Custom Resources.
- Utilizar exclusivamente as policies autorizadas.
- Consultar o status de reconciliação das próprias associações.

**Vaultweaver**
- Validar as solicitações recebidas.
- Verificar as autorizações administrativas.
- Determinar a identidade dos recursos gerenciados.
- Controlar ownership e ciclo de vida das roles.
- Reconciliar as configurações no Vault.
- Expor o resultado através de Kubernetes Status Conditions.

---

## 3. Custom Resource Design

### VaultPolicy

Representa uma ACL Policy gerenciada pela equipe de plataforma.

**Regra:** desenvolvedores não devem possuir permissões para criar ou modificar esse recurso.

A estratégia para garantir uma única fonte autoritativa de policies no Vault compartilhado ainda precisa ser detalhada.

### VaultPolicyGrant

Recurso administrativo que determina quais Vault Policies podem ser utilizadas por determinado namespace Kubernetes.

**Características:**
- Armazenado no namespace administrativo do Vaultweaver.
- Gerenciado exclusivamente pela equipe de plataforma.
- Não acessível por desenvolvedores via Kubernetes RBAC.
- Ausência de autorização implica negação por padrão.

*Status: proposto para implementação.*

### VaultKubernetesRoleBinding

Representa a solicitação de associação entre uma identidade Kubernetes e um conjunto autorizado de Vault Policies.

**Restrições:**
- Deve respeitar o namespace do próprio CR.
- Somente policies autorizadas podem ser associadas.
- O desenvolvedor não define livremente o nome da role no Vault.
- Cada instância do CR possui identidade própria.

---

## 4. Identity & Ownership

### Identidade externa

Cada role será identificada considerando:

- Kubernetes Auth Mount do cluster.
- Namespace do Custom Resource.
- Nome do Custom Resource.
- UID do Custom Resource.

O algoritmo exato de geração de nomes ainda será definido.

### Ownership

As seguintes regras foram aprovadas:

1. Nenhuma role preexistente poderá ser adotada automaticamente.
2. A intenção de ownership deverá ser persistida antes de modificar o Vault.
3. O Vaultweaver deverá recusar operações quando não conseguir estabelecer ownership.
4. As ACLs do Vault deverão limitar cada Operator ao auth mount sob sua responsabilidade.
5. A exclusão de um CR não poderá remover uma role pertencente a outro recurso.

### Questões em aberto

- Onde persistir a intenção de ownership?
- Como comprovar ownership após um crash?
- Como tratar uma role existente com ownership não comprovado?
- Como impedir colisões entre CRs do mesmo cluster?
- Como recuperar uma operação parcialmente concluída?

Referência: [ADR-001 — Authorization and Ownership](./adr/001-authorization-and-ownership.md)

---

## 5. Authorization Model

O modelo de autorização utiliza uma separação entre a solicitação do desenvolvedor e os limites definidos pela plataforma.

### Regras

- O `VaultPolicyGrant` define as policies permitidas.
- O `VaultKubernetesRoleBinding` declara as policies solicitadas.
- O Vaultweaver valida a autorização antes de aplicar configurações no Vault.
- Nenhuma policy será considerada autorizada implicitamente.
- A alteração de um Grant deverá provocar a reavaliação dos recursos afetados.

### Revogação

Quando uma policy deixar de ser autorizada:

1. As roles afetadas deverão ser reavaliadas.
2. A policy revogada deverá ser removida das associações no Vault.
3. As policies ainda autorizadas deverão ser preservadas.
4. O CR deverá sinalizar que sua solicitação original não está integralmente autorizada.

Tokens anteriormente emitidos não serão revogados automaticamente pelo Operator no MVP. Seus limites de validade e renovação serão definidos pela plataforma.

### Grant Uniqueness

Cada namespace de aplicação poderá possuir no máximo um VaultPolicyGrant, armazenado no namespace 
administrativo do Vaultweaver. O campo spec.targetNamespace será imutável. A ausência de um Grant implicará
negação por padrão. A unicidade deverá ser garantida pela Kubernetes API, evitando conflitos entre declarações administrativas concorrentes.

---

## 6. Reconciliation & Event Handling

### Reconciliation Loop

O fluxo conceitual do controller de roles é:

1. Receber a solicitação de reconciliação.
2. Buscar o Custom Resource.
3. Determinar a identidade externa.
4. Consultar os limites de autorização.
5. Validar ownership e permissões.
6. Persistir a intenção de gerenciamento quando necessário.
7. Consultar o estado atual no Vault.
8. Aplicar as alterações permitidas.
9. Atualizar o status do Custom Resource.

O fluxo de exclusão será especificado separadamente.

### Event Sources

**VaultKubernetesRoleBinding**
- Criação.
- Atualização.
- Exclusão.

**VaultPolicyGrant**
- Criação.
- Atualização.
- Exclusão.

### Resource Mapping

O controller de VaultKubernetesRoleBinding observará eventos de VaultPolicyGrant utilizando Watches() e handler.EnqueueRequestsFromMapFunc.

O mapeamento identificará os VaultKubernetesRoleBinding pertencentes ao namespace definido em 
spec.targetNamespace, sem precisar listar todos os recursos do cluster.

**Decisões**:

- spec.targetNamespace será imutável.
- Alterações em allowedPolicies provocarão a reconciliação dos RoleBindings afetados.
- A exclusão de um Grant provocará a reavaliação das associações anteriormente autorizadas.
- A ausência de um Grant válido resultará em default deny.
- Os eventos do Grant não precisarão modificar os próprios RoleBindings para iniciar a reconciliação.

**Resiliência**:

Uma reconciliação periódica poderá complementar os eventos Kubernetes para detectar divergências 
persistentes. A frequência e as garantias de convergência ainda precisam ser definidas.

**Status**: Decisão arquitetural aprovada. Implementação pendente.

---

## 7. Failure Handling & Consistency

O Vaultweaver opera sobre dois sistemas independentes:

- Kubernetes API.
- HashiCorp Vault API.

Não existe transação distribuída entre eles.

O design deverá considerar:

- Crash antes da escrita no Vault.
- Crash após escrita no Vault, antes da confirmação.
- Indisponibilidade temporária do Vault.
- Erro de autenticação ou autorização.
- Falha de atualização do status Kubernetes.
- Conflitos de ownership.
- Falhas durante a execução de finalizers.
- Alterações externas no estado do Vault.

### Princípios

- Operações devem ser idempotentes.
- Retries não podem conceder acesso indevido.
- Falhas de autorização devem seguir *fail closed*.
- Estado persistido deve permitir recuperação segura.
- O status deve distinguir falhas operacionais de solicitações não autorizadas.

---

## 8. Observability

O Operator deverá utilizar Kubernetes Status Conditions para expor os resultados de reconciliação.

### Condições e razões previstas

| Ready | Reason | Significado |
|---|---|---|
| True | Reconciled | Estado autorizado e reconciliado |
| False | GrantNotFound | Grant administrativo ausente |
| False | PolicyNotAuthorized | Policy solicitada não autorizada |
| False | OwnershipConflict | Ownership não comprovado ou conflitante |
| False | ReconciliationFailed | Falha durante a aplicação do estado desejado |

A semântica final de status, retries e falhas parciais ainda deverá ser detalhada e validada com testes.

---

## 9. Testing Strategy

A estratégia de testes deverá cobrir:

**Authorization**
- Solicitação autorizada.
- Solicitação não autorizada.
- Namespace sem Grant.
- Revogação de uma policy previamente autorizada.

**Ownership**
- Criação de uma nova role.
- Role preexistente sem ownership.
- Recriação do CR com novo UID.
- Colisões e conflitos de identidade.

**Reconciliation**
- Execução idempotente.
- Recuperação após falha.
- Exclusão com finalizer.
- Alterações externas no Vault.

**Integration**
- Comunicação real com Vault.
- Autenticação Kubernetes.
- Validação de ACLs.
- Testes E2E em ambiente isolado.

Referência: [Authorization Scenarios](./scenarios/authorization.feature)

---

## 10. Open Design Questions

- [ ] Definir mecanismo de armazenamento da intenção de ownership.
- [ ] Definir contrato completo de criação e exclusão de roles.
- [ ] Definir algoritmo de identificação externa.
- [ ] Definir estratégia de mapeamento de eventos de `VaultPolicyGrant`.
- [ ] Definir estratégia de detecção e correção de drift.
- [ ] Definir semântica de campos opcionais na reconciliação.
- [ ] Definir limites de TTL administrados pela plataforma.
- [ ] Definir ciclo de vida e autoridade sobre `VaultPolicy` no Vault compartilhado.
- [ ] Definir política de retries e classificação de falhas.
- [ ] Validar isolamento e segurança da suíte E2E.

---

## 11. Architecture Decision Records

| ADR | Assunto | Status |
|---|---|---|
| [ADR-001](./adr/001-authorization-and-ownership.md) | Authorization and Ownership | Em elaboração |

## 12. Implementation Status

Este documento descreve principalmente a **arquitetura desejada para o MVP**, não o estado atual da implementação.

As decisões arquiteturais deverão ser refletidas no código e verificadas por testes antes que uma funcionalidade seja considerada concluída.

O desenvolvimento seguirá a sequência:

**Requisitos → Decisões arquiteturais → Cenários de comportamento → Implementação → Testes → Validação.**
