"""
Constantes do Sistema, Localização de Mercado (pt-AO) e Validações Regulatórias Angolanas.
Plataforma: Delivery / Ango_Ifood.

Implementa as regras de conformidade linguística, fiscal e financeira de Angola:
- RN-059: Padronização financeira e monetária em Kwanzas (Kz / AOA).
- RN-010: Regras de validação do Número de Identificação Fiscal (NIF) e Bilhete de Identidade (BI)
  conforme as diretrizes da Administração Geral Tributária (AGT) e Direção Nacional de Identificação.
- Adaptação Terminológica Pura:
    * 'Estafeta' -> 'Entregador'
    * 'Morada'   -> 'Endereço'
    * 'Numerário' -> 'Dinheiro Físico'
"""
import re
from decimal import Decimal
from typing import Any

from django.core.exceptions import ValidationError
from django.utils.translation import gettext_lazy as _

# ==============================================================================
# 1. MOEDA, SÍMBOLO MONETÁRIO E REGRAS FINANCEIRAS (RN-059)
# ==============================================================================
MOEDA_CODIGO_ISO: str = "AOA"
MOEDA_SIMBOLO: str = "Kz"
MOEDA_NOME: str = "Kwanza Angolano"

# Valores mínimos e limites operacionais (Secção 8.1 e RN-059)
VALOR_MINIMO_PEDIDO_KZ: Decimal = Decimal("2000.00")
VALOR_MINIMO_PEDIDO_CENTIMOS: int = 200000  # Em centavos/cêntimos inteiros para precisão

TAXA_ENTREGA_BASE_KZ: Decimal = Decimal("800.00")
TAXA_ENTREGA_KM_ADICIONAL_KZ: Decimal = Decimal("250.00")
LIMITE_COMPENSACAO_AGENTE_KZ: Decimal = Decimal("3000.00")  # Teto de alçada do agente (RN-106)


def formatar_moeda_kz(valor: Decimal | float | int | str) -> str:
    """
    Formata valores monetários para a convenção financeira oficial de Angola.
    Utiliza separador de milhar por ponto (.) e casas decimais por vírgula (,).
    Exemplo: 2000.00 -> '2.000,00 Kz'
    """
    try:
        dec_valor = Decimal(str(valor))
    except Exception:
        dec_valor = Decimal("0.00")

    # Formata com separador padrão e converte para convenção angolana
    formatado = f"{dec_valor:,.2f}"
    formatado_ao = formatado.replace(",", "X").replace(".", ",").replace("X", ".")
    return f"{formatado_ao} {MOEDA_SIMBOLO}"


def formatar_centimos_para_kz(centimos: int) -> str:
    """
    Converte unidades mínimas inteiras (centavos) para representação em Kwanza.
    Exemplo: 200000 -> '2.000,00 Kz'
    """
    dec_kz = Decimal(centimos) / Decimal(100)
    return formatar_moeda_kz(dec_kz)


# ==============================================================================
# 2. ADAPTAÇÃO TERMINOLÓGICA E MENSAGENS DO SISTEMA (pt-AO)
# ==============================================================================
# Termos Oficiais Localizados
TERMO_ENTREGADOR = _("Entregador")
TERMO_ENDERECO = _("Endereço")
TERMO_DINHEIRO_FISICO = _("Dinheiro Físico")

# Papéis de Utilizador (RBAC)
ROLE_CLIENTE = "CLIENTE"
ROLE_PARCEIRO = "PARCEIRO"
ROLE_ENTREGADOR = "ENTREGADOR"
ROLE_OPERACAO = "OPERACAO"
ROLE_ADMIN = "ADMIN"

ROLES_CHOICES = [
    (ROLE_CLIENTE, _("Cliente")),
    (ROLE_PARCEIRO, _("Parceiro Comercial (Restaurante / Loja)")),
    (ROLE_ENTREGADOR, TERMO_ENTREGADOR),
    (ROLE_OPERACAO, _("Operador de Suporte / Helpdesk")),
    (ROLE_ADMIN, _("Administrador do Sistema")),
]

# Meios de Pagamento Disponíveis no Mercado Angolano
PAGAMENTO_DINHEIRO_FISICO = "DINHEIRO_FISICO"
PAGAMENTO_MULTICAIXA_EXPRESS = "MULTICAIXA_EXPRESS"
PAGAMENTO_TRANSFERENCIA = "TRANSFERENCIA_IBAN"
PAGAMENTO_SALDO_CARTEIRA = "SALDO_CARTEIRA"

METODOS_PAGAMENTO_CHOICES = [
    (PAGAMENTO_MULTICAIXA_EXPRESS, _("Multicaixa Express (MCX / EMIS)")),
    (PAGAMENTO_DINHEIRO_FISICO, TERMO_DINHEIRO_FISICO),
    (PAGAMENTO_TRANSFERENCIA, _("Transferência Bancária / Pagamento por Referência")),
    (PAGAMENTO_SALDO_CARTEIRA, _("Saldo da Carteira Digital")),
]

# Mensagens Padronizadas e Erros Semânticos do Sistema (pt-AO)
MENSAGENS_SISTEMA = {
    # Financeiro e Checkout
    "PEDIDO_VALOR_MINIMO": _(f"O valor mínimo do pedido é de {formatar_moeda_kz(VALOR_MINIMO_PEDIDO_KZ)}."),
    "PAGAMENTO_DINHEIRO_PENDENTE": _(f"Pagamento em {TERMO_DINHEIRO_FISICO} a ser efetuado ao {TERMO_ENTREGADOR} no momento da entrega."),
    "TROCO_OBRIGATORIO": _("Indique o valor para cálculo do troco em Dinheiro Físico."),

    # Logística e Entregadores
    "ENTREGADOR_NAO_ENCONTRADO": _(f"Nenhum {TERMO_ENTREGADOR.lower()} disponível nas imediações do estabelecimento."),
    "ENTREGADOR_A_CAMINHO": _(f"O seu {TERMO_ENTREGADOR.lower()} já se encontra a caminho do seu {TERMO_ENDERECO.lower()}."),
    "ENDERECO_FORA_COBERTURA": _(f"O seu {TERMO_ENDERECO.lower()} de entrega encontra-se fora do raio de cobertura desta loja."),
    "ENDERECO_OBRIGATORIO": _(f"É obrigatório selecionar ou introduzir um {TERMO_ENDERECO.lower()} válido de entrega."),
    "PIN_ENTREGA_EXPLICACAO": _(f"Partilhe este código PIN de 4 dígitos apenas com o {TERMO_ENTREGADOR.lower()} ao receber a sua encomenda."),

    # Suporte e Disputas
    "LIMITE_COMPENSACAO_EXCEDIDO": _(
        f"A compensação excede o teto permitido de {formatar_moeda_kz(LIMITE_COMPENSACAO_AGENTE_KZ)} para Agentes. "
        "Exige autorização prévia de um Supervisor de Operações."
    ),
    "DISPUTA_RESOLVIDA_REEMBOLSO": _("Disputa resolvida com crédito creditado na carteira em Kwanzas (Kz)."),
}


# ==============================================================================
# 3. VALIDAÇÃO DE DOCUMENTOS ANGOLANOS (AGT & DNIC - RN-010)
# ==============================================================================
# Siglas provinciais oficiais de emissão do Bilhete de Identidade em Angola
SIGLAS_PROVINCIAS_BI = {
    "BO",  # Bengo
    "BA",  # Benguela
    "BE",  # Bié
    "CA", "CB",  # Cabinda
    "CC",  # Cuando Cubango
    "CN",  # Cuanza Norte
    "CS",  # Cuanza Sul
    "CU",  # Cunene
    "HA",  # Huambo
    "HL", "HU",  # Huíla
    "LA", "LD",  # Luanda
    "LN",  # Lunda Norte
    "LS",  # Lunda Sul
    "ME", "ML",  # Malanje
    "MO", "MX",  # Moxico
    "NA", "NB",  # Namibe
    "UE", "UI",  # Uíge
    "ZE", "ZA",  # Zaire
}

# Expressão regular: 9 dígitos + 2 letras maiúsculas + 3 dígitos (Total: 14 caracteres)
PADRAO_BI_ANGOLANO = re.compile(r"^[0-9]{9}[A-Z]{2}[0-9]{3}$")

# NIF Coletivo (Empresas / Sociedades Comerciais): Exatamente 10 dígitos numéricos
PADRAO_NIF_EMPRESA = re.compile(r"^[0-9]{10}$")

# IBAN de Angola (EMIS): Código de país AO + 06 + 21 dígitos da conta bancária (25 caracteres)
PADRAO_IBAN_ANGOLANO = re.compile(r"^AO06[0-9]{21}$")

# Telefones de Angola: Operadoras 91, 92, 93, 94, 95, 97, 99 (9 dígitos locais ou +244)
PADRAO_TELEFONE_ANGOLANO = re.compile(r"^(\+?244)?9[1-579][0-9]{7}$")


def validar_bi_angolano(bi_valor: Any) -> str:
    """
    RN-010 / RN-082: Valida o Bilhete de Identidade (BI) de cidadão angolano.
    Estrutura exigida pela DNIC / Ministério da Justiça:
      - 9 dígitos numéricos
      - 2 letras maiúsculas correspondentes à província ou código de emissão
      - 3 dígitos de controlo sequencial
    Exemplo válido: '004567890LA042'
    """
    if not bi_valor:
        raise ValidationError(
            _("O Bilhete de Identidade (BI) é de preenchimento obrigatório."),
            code="bi_obrigatorio",
        )

    bi_limpo = str(bi_valor).strip().upper().replace(" ", "").replace("-", "").replace(".", "")

    if len(bi_limpo) != 14:
        raise ValidationError(
            _(f"O Bilhete de Identidade deve conter exatamente 14 caracteres. Introduzido: '{bi_limpo}'."),
            code="bi_comprimento_invalido",
        )

    if not PADRAO_BI_ANGOLANO.match(bi_limpo):
        raise ValidationError(
            _(
                "Formato de BI angolano inválido. O formato oficial deve conter 9 dígitos numéricos, "
                "seguidos de 2 letras maiúsculas (sigla provincial) e 3 dígitos finais (ex: 004567890LA042)."
            ),
            code="bi_formato_invalido",
        )

    sigla_provincia = bi_limpo[9:11]
    if sigla_provincia not in SIGLAS_PROVINCIAS_BI:
        raise ValidationError(
            _(
                f"Sigla provincial '{sigla_provincia}' não é reconhecida no sistema de identificação de Angola. "
                "Verifique os dados no seu Bilhete de Identidade original."
            ),
            code="bi_provincia_invalida",
        )

    return bi_limpo


def validar_nif_angolano(nif_valor: Any) -> str:
    """
    RN-010: Valida o Número de Identificação Fiscal (NIF) segundo as regras da AGT (Angola).
    O NIF pode ser:
      1. Pessoa Singular: Equivalente ao BI de 14 caracteres (9 dígitos + 2 letras + 3 dígitos).
      2. Pessoa Coletiva (Empresa / Loja Parceira): Composto rigorosamente por 10 dígitos numéricos.
    Exemplos válidos:
      - Empresa: '5417088921', '5001234567'
      - Singular: '004567890LA042'
    """
    if not nif_valor:
        raise ValidationError(
            _("O Número de Identificação Fiscal (NIF) é de preenchimento obrigatório."),
            code="nif_obrigatorio",
        )

    nif_limpo = str(nif_valor).strip().upper().replace(" ", "").replace("-", "").replace(".", "").replace("/", "")

    # Caso 1: NIF de Pessoa Coletiva (Empresas, Restaurantes e Parceiros Comerciais)
    if nif_limpo.isdigit():
        if len(nif_limpo) != 10:
            raise ValidationError(
                _(
                    f"O NIF de Pessoa Coletiva (Empresa) deve conter exatamente 10 dígitos numéricos. "
                    f"Introduzido: '{nif_limpo}' ({len(nif_limpo)} dígitos)."
                ),
                code="nif_coletivo_comprimento_invalido",
            )
        return nif_limpo

    # Caso 2: NIF de Pessoa Singular (Equiparado ao Bilhete de Identidade)
    if len(nif_limpo) == 14:
        return validar_bi_angolano(nif_limpo)

    raise ValidationError(
        _(
            "Número de Identificação Fiscal (NIF) inválido perante a AGT. "
            "Para Empresas introduza o NIF numérico de 10 dígitos. "
            "Para Empresários em Nome Individual introduza o BI de 14 caracteres (ex: 004567890LA042)."
        ),
        code="nif_formato_invalido",
    )


def validar_iban_angolano(iban_valor: Any) -> str:
    """
    RN-010 / RN-082 / Secção 7: Valida o IBAN angolano emitido pelo sistema bancário (EMIS/BNA).
    Formato: 'AO06' seguido de 21 dígitos numéricos (Total: 25 caracteres).
    """
    if not iban_valor:
        raise ValidationError(_("O IBAN bancário é obrigatório para liquidação de valores."), code="iban_obrigatorio")

    iban_limpo = str(iban_valor).strip().upper().replace(" ", "").replace(".", "")

    if len(iban_limpo) != 25 or not PADRAO_IBAN_ANGOLANO.match(iban_limpo):
        raise ValidationError(
            _(
                "IBAN angolano inválido. O formato bancário nacional deve iniciar com 'AO06' "
                f"seguido de 21 dígitos da conta bancária (Total: 25 caracteres). Introduzido: '{iban_limpo}'."
            ),
            code="iban_angola_invalido",
        )

    return iban_limpo


def validar_telefone_angolano(telefone_valor: Any) -> str:
    """
    RN-001: Valida o número de telemóvel angolano (Unitel, Movicel, Africell).
    Aceita: 9XXXXXXXX ou +2449XXXXXXXX.
    """
    if not telefone_valor:
        raise ValidationError(_("O número de telemóvel é obrigatório."), code="telefone_obrigatorio")

    tel_limpo = str(telefone_valor).strip().replace(" ", "").replace("-", "")

    if not PADRAO_TELEFONE_ANGOLANO.match(tel_limpo):
        raise ValidationError(
            _(
                "Número de telemóvel inválido para Angola. "
                "Deve conter 9 dígitos iniciando com prefixos nacionais válidos (91, 92, 93, 94, 95, 97, 99)."
            ),
            code="telefone_angola_invalido",
        )

    # Padroniza para formato internacional +244...
    if not tel_limpo.startswith("+244"):
        if tel_limpo.startswith("244"):
            tel_limpo = f"+{tel_limpo}"
        else:
            tel_limpo = f"+244{tel_limpo}"

    return tel_limpo


# ==============================================================================
# 4. VALIDADORES REUTILIZÁVEIS PARA SERIALIZERS DO DJANGO REST FRAMEWORK (DRF)
# ==============================================================================
class NIFValidator:
    """Validador de campo para Django REST Framework que assegura NIF válido perante a AGT."""

    def __call__(self, value: Any) -> None:
        validar_nif_angolano(value)


class BIValidator:
    """Validador de campo para DRF que assegura Bilhete de Identidade válido de Angola."""

    def __call__(self, value: Any) -> None:
        validar_bi_angolano(value)


class IBANValidator:
    """Validador de campo para DRF que valida a estrutura bancária EMIS do IBAN de Angola."""

    def __call__(self, value: Any) -> None:
        validar_iban_angolano(value)


class TelefoneAngolanoValidator:
    """Validador de campo para DRF para telemóveis angolanos."""

    def __call__(self, value: Any) -> None:
        validar_telefone_angolano(value)
