# Diretrizes Permanentes de Governança e Controlo do Django Admin (Delivery Pro)

> **Documento Normativo e de Cumprimento Obrigatório para Todos os Desenvolvedores, Engenheiros e Agentes de IA que operam neste repositório.**

A plataforma **Delivery Pro** opera fluxos transacionais, pagamentos e logística em tempo real em Angola. Para garantir integridade fiscal, conformidade contra fraudes e controle operacional total, **nenhuma nova funcionalidade, modelo de dados ou endpoint é considerado concluído sem cumprir estritamente as 3 Regras de Ouro abaixo**.

---

## 🏆 As Três Regras de Ouro da Governança

### 1. Todo o Modelo Deve Pertencer ao Django Admin (`MasterModelAdmin`)
* **Regra:** Nenhuma tabela ou entidade no banco de dados pode ficar "órfã" ou invisível para os administradores do sistema.
* **Implementação:** Toda classe em `admin.py` deve herdar obrigatoriamente de `core.admin_base.MasterModelAdmin` (ou de `ImmutableFinancialAdmin` para entidades financeiras/ledger).
* **Auditoria Ativa:** O núcleo do sistema (`core.admin_audit.audit_and_register_orphaned_models`) realiza uma varredura automática no arranque (`ready()`). Qualquer modelo que seja esquecido pelo desenvolvedor será imediatamente auto-registado com a classe `AutoMasterAdmin` e emitirá um alerta no log do servidor:
  ```text
  [ADMIN AUDIT] Modelo 'sua_app.NovoModelo' registado automaticamente para controlo total.
  ```

---

### 2. Zero Parâmetros "Hardcoded" (Uso Obrigatório de `SystemConfiguration`)
* **Regra:** É estritamente proibido fixar valores monetários, taxas de entrega, percentagens de comissão, limites de tempo ou flags de ativação diretamente no código-fonte Python/Dart.
* **Implementação:** Toda regra de negócio configurável deve ser adicionada como campo no modelo `core.models.SystemConfiguration` e lida através do método com cache de alto desempenho:
  ```python
  from core.models import SystemConfiguration

  config = SystemConfiguration.get_settings()
  taxa_base = config.taxa_base_entrega_aoa
  comissao = config.comissao_marketplace_percentagem
  entregas_ativas = config.entregas_ativas
  ```
* **Impacto Operacional:** O superadministrador pode alterar preços e regras ou ligar o **Modo de Manutenção** instantaneamente pelo Django Admin sem necessidade de fazer deploy ou reiniciar containers em produção.

---

### 3. Toda Ação Crítica de API Deve Ser Visualizável, Auditável e Reversível
* **Regra:** Qualquer transação realizada via API (Mobile/Web) que envolva dinheiro, saldos, status de pedidos, bloqueio de contas ou despacho de estafetas deve deixar uma trilha transparente no Django Admin.
* **Proteção contra Exclusão Acidental:** Tabelas críticas (pedidos, pagamentos, carteiras, logs de auditoria) devem possuir a flag:
  ```python
  protected_from_deletion = True
  ```
  Isso bloqueia a ação massiva `delete_selected` e a exclusão física por SQL, exigindo **Soft Delete** (`is_active = False`) ou **estorno compensatório**.
* **Trilha de Auditoria:** O `MasterModelAdmin` grava no `django.contrib.admin.models.LogEntry` o utilizador autenticado, timestamp e o endereço **IP real** de cada mutação.

---

## 📋 Checklist Obrigatório de Pull Request / Entrega de Tarefas

Antes de considerar qualquer tarefa finalizada, verifique:

- [ ] **Modelos Criados:** Todos herdam de `AuditedModel` (ou possuem campos de data e `is_active`)?
- [ ] **Admin Registado:** A classe admin foi criada em `admin.py` herdando de `MasterModelAdmin` ou `ImmutableFinancialAdmin`?
- [ ] **Performance:** O admin define `list_select_related = True` ou `autocomplete_fields` para relações de chave estrangeira?
- [ ] **Exportação:** A ação de exportação para CSV foi testada e mantém compatibilidade com Excel (UTF-8 com BOM)?
- [ ] **Regras de Negócio:** Se há valores ou limites (AOA, %, tempos), eles estão declarados no `SystemConfiguration`?
- [ ] **Logística/Rotas:** O endpoint consome parâmetros de frete dinâmicos e possui fallback resiliente?

---

## 🛠️ Exemplo de Implementação de Admin de Governança

```python
# apps/exemplo/admin.py
from django.contrib import admin
from core.admin_base import MasterModelAdmin, ImmutableFinancialAdmin
from apps.exemplo.models import PedidoExemplo, TransacaoExemplo

@admin.register(PedidoExemplo)
class PedidoExemploAdmin(MasterModelAdmin):
    protected_from_deletion = True  # Impede deleção física
    list_display = ("id", "cliente", "valor_total", "status", "criado_em")
    list_filter = ("status", "criado_em")
    search_fields = ("id", "cliente__telemovel", "cliente__email")
    autocomplete_fields = ("cliente",)

@admin.register(TransacaoExemplo)
class TransacaoExemploAdmin(ImmutableFinancialAdmin):
    # Registos financeiros são 100% Read-Only para prevenir fraudes contábeis
    list_display = ("id", "tipo", "montante_aoa", "referencia", "criado_em")
    list_filter = ("tipo", "criado_em")
    search_fields = ("referencia",)
```
