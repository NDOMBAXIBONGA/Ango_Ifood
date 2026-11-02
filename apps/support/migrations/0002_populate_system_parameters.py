"""
Migração de Dados (Data Migration) do Django para aprovisionamento dos Parâmetros da Secção 8.
Garante idempotência estrita via `update_or_create` e suporte a reversão (rollback).
"""
from decimal import Decimal
from django.db import migrations
from django.utils import timezone


PARAMETROS_SECCAO_8 = [
    {
        "chave": "JANELA_CANCELAMENTO_GRATUITO",
        "nome": "Janela de cancelamento gratuito",
        "valor": "60s",
        "valor_numerico": Decimal("60.00"),
        "unidade": "segundos",
        "ambito": "Global",
        "regra_associada": "RN-102",
        "descricao": (
            "O cliente pode cancelar sem custos nos primeiros 60 segundos após confirmação, "
            "ou enquanto o parceiro ainda não aceitou, sem qualquer retenção (RN-102)."
        ),
    },
    {
        "chave": "PRAZO_ACEITACAO_PARCEIRO",
        "nome": "Prazo de aceitação do parceiro",
        "valor": "3 min",
        "valor_numerico": Decimal("180.00"),
        "unidade": "segundos",
        "ambito": "Parceiro",
        "regra_associada": "RN-075",
        "descricao": (
            "O parceiro tem um prazo de 3 minutos para aceitar. Aos 90 segundos é enviado "
            "um lembrete reforçado; no fim do prazo, o pedido é rejeitado e reembolsado (RN-075)."
        ),
    },
    {
        "chave": "TIMEOUT_OFERTA_ESTAFETA",
        "nome": "Timeout de oferta ao estafeta",
        "valor": "30s",
        "valor_numerico": Decimal("30.00"),
        "unidade": "segundos",
        "ambito": "Zona",
        "regra_associada": "RN-086",
        "descricao": (
            "Cada oferta expira em 30 segundos. Em caso de ninguém aceitar, o raio de procura "
            "aumenta gradualmente e pode subir o incentivo (RN-086)."
        ),
    },
    {
        "chave": "RAIO_INICIAL_PROCURA_ESTAFETAS",
        "nome": "Raio inicial de procura de estafetas",
        "valor": "3 km",
        "valor_numerico": Decimal("3.00"),
        "unidade": "km",
        "ambito": "Zona",
        "regra_associada": "RN-086",
        "descricao": (
            "Raio inicial de procura de estafetas (3 km), a expandir gradualmente até 7 km "
            "caso nenhum estafeta aceite a corrida inicial (RN-086)."
        ),
    },
    {
        "chave": "RAIO_MAXIMO_ENTREGA",
        "nome": "Raio máximo de entrega",
        "valor": "7 km",
        "valor_numerico": Decimal("7.00"),
        "unidade": "km",
        "ambito": "Loja",
        "regra_associada": "RN-025",
        "descricao": (
            "Cada loja entrega num raio e/ou polígono configurável (7 km). "
            "Moradas fora da zona não podem concluir o pedido (RN-025)."
        ),
    },
    {
        "chave": "PEDIDO_MINIMO_PADRAO",
        "nome": "Pedido mínimo padrão",
        "valor": "2000 Kz",
        "valor_numerico": Decimal("2000.00"),
        "unidade": "Kz",
        "ambito": "Loja",
        "regra_associada": "RN-041",
        "descricao": (
            "Valor mínimo padrão de subtotal por loja (2.000 Kz). Abaixo desse valor, "
            "o cliente paga taxa de pequeno pedido ou é impedido de finalizar (RN-041)."
        ),
    },
    {
        "chave": "VALIDADE_COTACAO",
        "nome": "Validade da cotação",
        "valor": "15 min",
        "valor_numerico": Decimal("900.00"),
        "unidade": "segundos",
        "ambito": "Global",
        "regra_associada": "RN-043",
        "descricao": (
            "A cotação (preços, taxas, ETA) é válida por 15 minutos em Redis. "
            "Após expirar, é recalculada e o cliente informado das diferenças (RN-043)."
        ),
    },
    {
        "chave": "TAXA_SERVICO_BASE",
        "nome": "Taxa de serviço base",
        "valor": "5%",
        "valor_numerico": Decimal("5.00"),
        "unidade": "%",
        "ambito": "Pais",
        "regra_associada": "RN-053",
        "descricao": (
            "Percentagem da taxa de serviço da plataforma (5% com mínimo de 100 Kz e máximo de 500 Kz) (RN-053)."
        ),
    },
    {
        "chave": "COMISSAO_PARCEIRO_PADRAO",
        "nome": "Comissão do parceiro padrão",
        "valor": "20%",
        "valor_numerico": Decimal("20.00"),
        "unidade": "%",
        "ambito": "Contrato",
        "regra_associada": "RN-054",
        "descricao": (
            "Percentagem média padrão sobre o subtotal de produtos (gama contratual: 15% a 30%) (RN-054)."
        ),
    },
    {
        "chave": "TETO_PRECO_DINAMICO",
        "nome": "Teto de preço dinâmico",
        "valor": "2x taxa base",
        "valor_numerico": Decimal("2.00"),
        "unidade": "multiplicador",
        "ambito": "Zona",
        "regra_associada": "RN-052",
        "descricao": (
            "Em picos de procura ou escassez de estafetas, a taxa pode subir até ao teto de 2x (RN-052)."
        ),
    },
    {
        "chave": "ESPERA_MAXIMA_LOJA",
        "nome": "Espera máxima na loja (bónus a partir de)",
        "valor": "10 min",
        "valor_numerico": Decimal("600.00"),
        "unidade": "segundos",
        "ambito": "Global",
        "regra_associada": "RN-089",
        "descricao": (
            "Se o estafeta esperar mais de 10 minutos na loja por culpa do parceiro, "
            "recebe bónus de espera (RN-089)."
        ),
    },
    {
        "chave": "ESPERA_MAXIMA_CLIENTE",
        "nome": "Espera máxima pelo cliente",
        "valor": "7 min",
        "valor_numerico": Decimal("420.00"),
        "unidade": "segundos",
        "ambito": "Global",
        "regra_associada": "RN-096",
        "descricao": (
            "O estafeta aguarda o cliente durante 7 minutos obrigatórios. Sem sucesso, "
            "pode encerrar como falha de entrega por culpa do cliente (RN-096/RN-097)."
        ),
    },
    {
        "chave": "TENTATIVAS_MAX_PAGAMENTO",
        "nome": "Tentativas de pagamento",
        "valor": "3",
        "valor_numerico": Decimal("3.00"),
        "unidade": "tentativas",
        "ambito": "Global",
        "regra_associada": "RN-067",
        "descricao": (
            "Após 3 falhas consecutivas, o método de pagamento é temporariamente bloqueado (RN-067)."
        ),
    },
    {
        "chave": "VALIDADE_OTP",
        "nome": "Validade do OTP",
        "valor": "5 min / 5 tentativas",
        "valor_numerico": Decimal("300.00"),
        "unidade": "segundos",
        "ambito": "Global",
        "regra_associada": "RN-002",
        "descricao": (
            "O código OTP expira em 5 minutos, permite no máximo 5 tentativas e o reenvio "
            "é limitado a 3 por hora para evitar abuso (RN-002)."
        ),
    },
    {
        "chave": "JANELA_AVALIACAO",
        "nome": "Janela de avaliação",
        "valor": "72 h",
        "valor_numerico": Decimal("72.00"),
        "unidade": "horas",
        "ambito": "Global",
        "regra_associada": "RN-112",
        "descricao": (
            "Apenas clientes com pedido entregue e dentro da janela de 72 horas podem avaliar (RN-112)."
        ),
    },
    {
        "chave": "JANELA_RECLAMACAO_RETENCAO",
        "nome": "Janela de reclamação / retenção",
        "valor": "48 h",
        "valor_numerico": Decimal("48.00"),
        "unidade": "horas",
        "ambito": "Global",
        "regra_associada": "RN-147",
        "descricao": (
            "Os valores ficam retidos durante 48 horas após a entrega para cobrir eventuais "
            "reembolsos, reclamações e disputas (RN-147)."
        ),
    },
    {
        "chave": "CICLO_LIQUIDACAO_PARCEIROS",
        "nome": "Ciclo de liquidação a parceiros",
        "valor": "Semanal",
        "valor_numerico": Decimal("7.00"),
        "unidade": "dias",
        "ambito": "Contrato",
        "regra_associada": "RN-145",
        "descricao": (
            "Liquidação financeira semanal por defeito a parceiros comerciais com extrato detalhado (RN-145)."
        ),
    },
    {
        "chave": "LIMITE_COMPENSACAO_AGENTE",
        "nome": "Limite de compensação por agente",
        "valor": "3.000 Kz",
        "valor_numerico": Decimal("3000.00"),
        "unidade": "Kz",
        "ambito": "Perfil",
        "regra_associada": "RN-106",
        "descricao": (
            "Agentes de suporte só podem conceder créditos até 3.000 Kz por caso. "
            "Valores acima exigem aprovação de supervisor (RN-106)."
        ),
    },
    {
        "chave": "ATRASO_COMPENSACAO_AUTOMATICA",
        "nome": "Atraso que dá direito a compensação",
        "valor": "20 min acima da ETA",
        "valor_numerico": Decimal("20.00"),
        "unidade": "minutos",
        "ambito": "Global",
        "regra_associada": "RN-099",
        "descricao": (
            "Se o atraso exceder a ETA prometida em mais de 20 minutos, o cliente pode cancelar "
            "sem custos ou receber compensação automática (RN-099)."
        ),
    },
    {
        "chave": "TAXA_CANCELAMENTO_PARCEIRO_ALERTA",
        "nome": "Taxa de cancelamento do parceiro (alerta)",
        "valor": "5% mensal",
        "valor_numerico": Decimal("5.00"),
        "unidade": "%",
        "ambito": "Parceiro",
        "regra_associada": "RN-104",
        "descricao": (
            "Taxa de cancelamento do parceiro acima de 5% mensal gera alerta de auditoria "
            "e revisão contratual (RN-104)."
        ),
    },
]


def popular_parametros_seccao_8(apps, schema_editor):
    """Insere ou atualiza os parâmetros operacionais da Secção 8 de forma idempotente."""
    Parametro = apps.get_model("support", "Parametro")
    agora = timezone.now()

    for item in PARAMETROS_SECCAO_8:
        Parametro.objects.update_or_create(
            chave=item["chave"],
            defaults={
                "nome": item["nome"],
                "valor": item["valor"],
                "valor_numerico": item["valor_numerico"],
                "unidade": item["unidade"],
                "ambito": item["ambito"],
                "regra_associada": item["regra_associada"],
                "descricao": item["descricao"],
                "vigencia_inicio": agora,
                "versao": 1,
                "autor": "DevOps / DataMigration",
            },
        )


def reverter_parametros_seccao_8(apps, schema_editor):
    """Reverte a inserção dos parâmetros em caso de rollback da migração."""
    Parametro = apps.get_model("support", "Parametro")
    chaves = [item["chave"] for item in PARAMETROS_SECCAO_8]
    Parametro.objects.filter(chave__in=chaves).delete()


class Migration(migrations.Migration):

    dependencies = [
        ("support", "__first__"),
    ]

    operations = [
        migrations.RunPython(
            popular_parametros_seccao_8,
            reverse_code=reverter_parametros_seccao_8,
        ),
    ]
