"""
Comando de gestão customizado do Django (`manage.py setup_system_parameters`).
Popula de forma automática, estruturada e idempotente a tabela `Parametro` (Secção 8 e 11).
Insere todos os parâmetros predefinidos e SLAs operacionais descritos na especificação funcional:

- Janela de cancelamento gratuito: '60s', âmbito: 'Global' (RN-102)
- Prazo de aceitação do parceiro: '3 min', âmbito: 'Parceiro' (RN-075)
- Timeout de oferta ao estafeta: '30s', âmbito: 'Zona' (RN-086)
- Raio inicial de procura de estafetas: '3 km', âmbito: 'Zona' (RN-086)
- Pedido mínimo padrão: '2000 Kz', âmbito: 'Loja' (RN-041)
- Taxa de serviço base: '5%', âmbito: 'Pais' (RN-053)
E os demais parâmetros operacionais da Tabela da Secção 8.

Garante integridade e idempotência estrita via `update_or_create` para não duplicar registos.
"""
from __future__ import annotations

import sys
from decimal import Decimal
from typing import Any

from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from apps.support.models import Parametro


# Tabela canónica de Parâmetros Operacionais da Secção 8
PARAMETROS_SECCAO_8: list[dict[str, Any]] = [
    {
        "chave": "JANELA_CANCELAMENTO_GRATUITO",
        "nome": "Janela de cancelamento gratuito",
        "valor": "60s",
        "valor_numerico": Decimal("60.00"),
        "unidade": "segundos",
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.PARCEIRO,
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
        "ambito": Parametro.AmbitoParametro.ZONA,
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
        "ambito": Parametro.AmbitoParametro.ZONA,
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
        "ambito": Parametro.AmbitoParametro.LOJA,
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
        "ambito": Parametro.AmbitoParametro.LOJA,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.PAIS,
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
        "ambito": Parametro.AmbitoParametro.CONTRATO,
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
        "ambito": Parametro.AmbitoParametro.ZONA,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.CONTRATO,
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
        "ambito": Parametro.AmbitoParametro.PERFIL,
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
        "ambito": Parametro.AmbitoParametro.GLOBAL,
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
        "ambito": Parametro.AmbitoParametro.PARCEIRO,
        "regra_associada": "RN-104",
        "descricao": (
            "Taxa de cancelamento do parceiro acima de 5% mensal gera alerta de auditoria "
            "e revisão contratual (RN-104)."
        ),
    },
]


class Command(BaseCommand):
    """
    Comando customizado do Django para aprovisionamento de Parâmetros Operacionais (Secção 8).
    Exemplo de uso:
        python manage.py setup_system_parameters
        python manage.py setup_system_parameters --force-update
        python manage.py setup_system_parameters --dry-run
    """

    help = "Popula a tabela Parametro de forma estruturada e idempotente com base na Secção 8."

    def add_arguments(self, parser) -> None:
        parser.add_argument(
            "--force-update",
            action="store_true",
            help="Força a atualização dos valores mesmo que o parâmetro já exista na base de dados.",
        )
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Simula a execução sem persistir dados na base de dados.",
        )

    def handle(self, *args: Any, **options: Any) -> None:
        force_update: bool = options.get("force_update", False)
        dry_run: bool = options.get("dry_run", False)

        self.stdout.write(self.style.MIGRATE_HEADING("=== Aprovisionamento de Parâmetros Operacionais e SLAs (Secção 8) ==="))
        if dry_run:
            self.stdout.write(self.style.WARNING("[MODO SIMULAÇÃO / DRY-RUN ATIVADO - NENHUM DADO SERÁ GRAVADO]"))

        criados = 0
        atualizados = 0
        inalterados = 0

        agora = timezone.now()

        with transaction.atomic():
            for item in PARAMETROS_SECCAO_8:
                chave = item["chave"]
                defaults = {
                    "nome": item["nome"],
                    "valor": item["valor"],
                    "valor_numerico": item["valor_numerico"],
                    "unidade": item["unidade"],
                    "ambito": item["ambito"],
                    "regra_associada": item["regra_associada"],
                    "descricao": item["descricao"],
                    "vigencia_inicio": agora,
                    "versao": 1,
                    "autor": "DevOps / setup_system_parameters",
                }

                if dry_run:
                    existe = Parametro.objects.filter(chave=chave).exists()
                    if existe:
                        self.stdout.write(f" [DRY-RUN] Parâmetro existente: {chave} ({item['valor']}) -> Atualizável={force_update}")
                    else:
                        self.stdout.write(f" [DRY-RUN] Novo parâmetro: {chave} ({item['valor']}) [Âmbito: {item['ambito']}]")
                    continue

                if force_update:
                    obj, created = Parametro.objects.update_or_create(
                        chave=chave,
                        defaults=defaults,
                    )
                    if created:
                        criados += 1
                        self.stdout.write(self.style.SUCCESS(f" [+] Criado: {chave} = '{obj.valor}' [Âmbito: {obj.ambito} | {obj.regra_associada}]"))
                    else:
                        atualizados += 1
                        self.stdout.write(self.style.WARNING(f" [~] Atualizado: {chave} = '{obj.valor}' [Âmbito: {obj.ambito}]"))
                else:
                    obj, created = Parametro.objects.get_or_create(
                        chave=chave,
                        defaults=defaults,
                    )
                    if created:
                        criados += 1
                        self.stdout.write(self.style.SUCCESS(f" [+] Criado: {chave} = '{obj.valor}' [Âmbito: {obj.ambito} | {obj.regra_associada}]"))
                    else:
                        inalterados += 1
                        self.stdout.write(f" [=] Já existente (sem alterações): {chave} = '{obj.valor}'")

        if dry_run:
            self.stdout.write(self.style.SUCCESS("Simulação concluída com sucesso."))
            return

        total_processado = len(PARAMETROS_SECCAO_8)
        self.stdout.write(self.style.MIGRATE_LABEL("-" * 75))
        self.stdout.write(
            self.style.SUCCESS(
                f"Concluído com sucesso! Total: {total_processado} | Criados: {criados} | "
                f"Atualizados: {atualizados} | Inalterados: {inalterados}"
            )
        )
