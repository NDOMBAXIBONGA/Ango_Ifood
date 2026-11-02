"""
Serviço Puro de Domínio Financeiro para Cálculo de Cotação de Checkout ('orders').
Implementa rigorosamente:
- Secção 6.5: Preços, taxas, comissões e promoções;
- Secção 7.1: Exemplo prático de um pedido e decomposição financeira;
- Secção 8: Parâmetros configuráveis da plataforma;
- RN-041: Pedido mínimo por loja e taxa de pequeno pedido;
- RN-043: Congelamento imutável da cotação em cache Redis por 15 minutos (TTL = 900s);
- RN-050: Fórmula linear do Total:
  Total = Subtotal + Taxa de Entrega + Taxa de Serviço + Taxa de Pequeno Pedido + Gorjeta - Descontos;
- RN-051: Taxa de entrega geográfica calculada via PostGIS: base + (preco_km * distancia_km);
- RN-052: Multiplicador dinâmico em sobrecarga (Surge Pricing) até ao teto de 2x com transparência;
- RN-053: Taxa de serviço (5% sobre subtotal) com limites absolutos de teto mínimo e máximo;
- RN-055 / RN-056: Validação de cupões, repartição do financiador e desconto;
- RN-059: Aritmética estritamente inteira em unidades monetárias mínimas (Cêntimos / Kz * 100),
  usando Decimal apenas para cálculos intermédios com arredondamento determinístico ROUND_HALF_UP.
"""
from __future__ import annotations

import hashlib
import json
import logging
import uuid
from datetime import timedelta
from decimal import Decimal, ROUND_HALF_UP
from typing import Any

from django.conf import settings
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework.exceptions import ValidationError as DRFValidationError

from apps.accounts.models import CustomUser, Morada
from apps.catalog.models import ItemMenu, OpcaoItem, ParceiroLoja
from apps.promotions.models import CupaoDesconto

logger = logging.getLogger(__name__)


class OrderPricingEngineError(DRFValidationError):
    """Exceção de domínio lançada pelo motor de preços quando uma regra financeira é violada."""

    def __init__(
        self,
        mensagem: str,
        codigo_regra: str = "PRICING_ERROR",
        detalhes: dict[str, Any] | None = None,
    ) -> None:
        self.mensagem = str(mensagem)
        self.codigo_regra = codigo_regra
        self.detalhes = detalhes or {}
        payload: dict[str, Any] = {
            "erro": self.mensagem,
            "codigo_regra": self.codigo_regra,
        }
        if self.detalhes:
            payload["detalhes"] = self.detalhes
        super().__init__(detail=payload, code=codigo_regra)


class OrderPricingEngineService:
    """
    Motor financeiro puro em Python para cotação de checkout, taxas, descontos e totalização.
    Todos os cálculos utilizam estritamente números inteiros (unidades mínimas da moeda - RN-059).
    """

    # =========================================================================
    # PARÂMETROS PADRÃO CONFIGURÁVEIS (Secção 8 & RN-059)
    # Nota: 1 Kz = 100 cêntimos / unidades mínimas. Ex.: 2.000 Kz = 200_000 un.
    # =========================================================================

    # RN-041: Subtotal mínimo por defeito da loja (2.000 Kz = 200_000 cêntimos)
    DEFAULT_PEDIDO_MINIMO_LOJA: int = getattr(
        settings, "ORDER_SUBTOTAL_MINIMO_LOJA", 200_000
    )

    # RN-051: Parâmetros da taxa de entrega geográfica PostGIS
    DEFAULT_TAXA_ENTREGA_BASE: int = getattr(
        settings, "TAXA_ENTREGA_BASE", 50_000  # 500 Kz em unidades mínimas
    )
    DEFAULT_PRECO_POR_KM: int = getattr(
        settings, "PRECO_POR_KM", 15_000  # 150 Kz/km em unidades mínimas
    )

    # RN-052: Teto máximo do multiplicador dinâmico de sobrecarga (Surge Pricing)
    SURGE_MULTIPLIER_MAXIMO: Decimal = Decimal("2.00")
    SURGE_MULTIPLIER_MINIMO: Decimal = Decimal("1.00")

    # RN-053: Taxa de serviço da plataforma (5% sobre subtotal, mín. 100 Kz, máx. 500 Kz)
    TAXA_SERVICO_PERCENTAGEM: Decimal = Decimal("5.00")
    DEFAULT_TAXA_SERVICO_MINIMA: int = getattr(
        settings, "TAXA_SERVICO_MINIMA", 10_000  # 100 Kz em unidades mínimas
    )
    DEFAULT_TAXA_SERVICO_MAXIMA: int = getattr(
        settings, "TAXA_SERVICO_MAXIMA", 50_000  # 500 Kz em unidades mínimas
    )

    # RN-043: TTL imutável da cotação em cache Redis (15 minutos = 900 segundos)
    COTACAO_TTL_SEGUNDOS: int = 15 * 60
    CACHE_KEY_PREFIX: str = "checkout:cotacao:{cotacao_id}"

    # =========================================================================
    # MÉTODOS AUXILIARES DE ARITMÉTICA DETERMINÍSTICA (RN-059)
    # =========================================================================

    @staticmethod
    def _arredondar_inteiro(valor_decimal: Decimal) -> int:
        """
        RN-059: Arredonda um Decimal intermédio deterministamente com ROUND_HALF_UP
        para o inteiro mais próximo.
        """
        return int(valor_decimal.quantize(Decimal("1"), rounding=ROUND_HALF_UP))

    @classmethod
    def _converter_inteiro(cls, valor: Any, campo: str) -> int:
        """Valida que o valor é um número inteiro não negativo (RN-059)."""
        if isinstance(valor, bool) or isinstance(valor, float):
            raise OrderPricingEngineError(
                mensagem=_(f"O campo '{campo}' deve ser um número inteiro (RN-059)."),
                codigo_regra="RN-059",
                detalhes={"campo": campo, "valor": str(valor)},
            )
        try:
            val_int = int(valor)
        except (TypeError, ValueError) as exc:
            raise OrderPricingEngineError(
                mensagem=_(f"O campo '{campo}' contém um valor inválido."),
                codigo_regra="RN-059",
                detalhes={"campo": campo, "valor": str(valor)},
            ) from exc

        if val_int < 0:
            raise OrderPricingEngineError(
                mensagem=_(f"O campo '{campo}' não pode ser negativo."),
                codigo_regra="RN-059",
                detalhes={"campo": campo, "valor": val_int},
            )
        return val_int

    # =========================================================================
    # MÉTODO PRINCIPAL: gerar_cotacao_checkout (RN-041, RN-043, RN-050 a RN-059)
    # =========================================================================

    @staticmethod
    def gerar_cotacao_checkout(
        utilizador: CustomUser,
        dados_carrinho: dict[str, Any] | str,
    ) -> dict[str, Any]:
        """
        Gera a cotação financeira completa e determinística de checkout com congelamento
        na cache Redis por 15 minutos (RN-043).

        Input esperado em `dados_carrinho`:
        {
            "loja_id": "uuid-da-loja",
            "itens": [
                {
                    "item_id": "uuid-do-item",
                    "quantidade": 2,
                    "opcoes": ["uuid-opcao-1", "uuid-opcao-2"],
                    "notas": "Sem cebola"
                }
            ],
            "morada_id": "uuid-da-morada",           # opcional (usa morada ativa se omitido)
            "gorjeta_estafeta": 50000,               # inteiro opcional (unidades mínimas)
            "cupao_codigo": "PROMO10",               # string opcional
            "fator_preco_dinamico": "1.25"           # multiplicador opcional da zona (RN-052)
        }
        """
        cls = OrderPricingEngineService
        agora = timezone.now()

        # 0. Deserialização de JSON caso necessário
        if isinstance(dados_carrinho, str):
            try:
                dados_carrinho = json.loads(dados_carrinho)
            except json.JSONDecodeError as exc:
                raise OrderPricingEngineError(
                    mensagem=_("O payload 'dados_carrinho' não é um JSON válido."),
                    codigo_regra="RN-040",
                ) from exc

        if not isinstance(dados_carrinho, dict):
            raise OrderPricingEngineError(
                mensagem=_("O parâmetro 'dados_carrinho' deve ser um dicionário estruturado."),
                codigo_regra="RN-040",
            )

        # Validação do utilizador
        if not utilizador or not getattr(utilizador, "is_authenticated", False):
            raise OrderPricingEngineError(
                mensagem=_("Utilizador não autenticado para geração de cotação."),
                codigo_regra="RN-006",
            )

        # ---------------------------------------------------------------------
        # 1. Extração dos Campos e Validação da Loja Única (RN-040)
        # ---------------------------------------------------------------------
        loja_id = dados_carrinho.get("loja_id")
        itens_input = dados_carrinho.get("itens")
        morada_id = dados_carrinho.get("morada_id")
        gorjeta_raw = dados_carrinho.get("gorjeta_estafeta", 0)
        cupao_codigo = dados_carrinho.get("cupao_codigo")
        fator_dinamico_input = dados_carrinho.get("fator_preco_dinamico")

        if not loja_id:
            raise OrderPricingEngineError(
                mensagem=_("O campo 'loja_id' é obrigatório para calcular a cotação (RN-040)."),
                codigo_regra="RN-040",
            )

        if not isinstance(itens_input, list) or len(itens_input) == 0:
            raise OrderPricingEngineError(
                mensagem=_("O carrinho deve conter pelo menos um item (RN-040)."),
                codigo_regra="RN-040",
            )

        gorjeta_estafeta: int = cls._converter_inteiro(
            gorjeta_raw if gorjeta_raw is not None else 0,
            campo="gorjeta_estafeta",
        )

        try:
            loja = ParceiroLoja.objects.get(pk=loja_id)
        except (ParceiroLoja.DoesNotExist, ValueError, ValidationError) as exc:
            raise OrderPricingEngineError(
                mensagem=_("A loja indicada não existe ou o ID é inválido."),
                codigo_regra="RN-040",
                detalhes={"loja_id": str(loja_id)},
            ) from exc

        # ---------------------------------------------------------------------
        # 2. Cálculo do Subtotal Real a partir da Base de Dados (RN-050)
        # ---------------------------------------------------------------------
        subtotal: int = 0
        total_unidades: int = 0
        linhas_discriminadas: list[dict[str, Any]] = []

        item_ids = [it.get("item_id") for it in itens_input if it.get("item_id")]
        itens_db = {
            str(it.id): it
            for it in ItemMenu.objects.select_related("categoria", "loja", "categoria__loja").filter(
                pk__in=item_ids
            )
        }

        # Coleta todas as opções requisitadas
        todas_opcoes_ids = []
        for it in itens_input:
            todas_opcoes_ids.extend(it.get("opcoes") or [])
        opcoes_db = {
            str(op.id): op
            for op in OpcaoItem.objects.filter(pk__in=todas_opcoes_ids)
        }

        for idx, linha in enumerate(itens_input):
            it_id = str(linha.get("item_id"))
            item_model = itens_db.get(it_id)

            if not item_model:
                raise OrderPricingEngineError(
                    mensagem=_(f"O item com ID '{it_id}' não foi encontrado no catálogo."),
                    codigo_regra="RN-014",
                    detalhes={"item_id": it_id},
                )

            # Validação de loja única (RN-040)
            item_loja = item_model.loja or (item_model.categoria.loja if item_model.categoria else None)
            if str(item_loja.id) != str(loja.id):
                raise OrderPricingEngineError(
                    mensagem=_(
                        f"O item '{item_model.nome}' pertence a outro estabelecimento. "
                        f"Todos os itens devem pertencer à mesma loja (RN-040)."
                    ),
                    codigo_regra="RN-040",
                    detalhes={"item_id": it_id, "item_loja_id": str(item_loja.id), "carrinho_loja_id": str(loja.id)},
                )

            if not item_model.is_disponivel:
                raise OrderPricingEngineError(
                    mensagem=_(f"O item '{item_model.nome}' encontra-se temporariamente indisponível (RN-015)."),
                    codigo_regra="RN-015",
                    detalhes={"item_id": it_id},
                )

            qtd = cls._converter_inteiro(linha.get("quantidade", 1), campo=f"itens[{idx}].quantidade")
            if qtd < 1:
                raise OrderPricingEngineError(
                    mensagem=_(f"A quantidade do item '{item_model.nome}' tem de ser pelo menos 1."),
                    codigo_regra="RN-042",
                )

            preco_base_item: int = int(item_model.preco)

            # Sub-opções selecionadas
            opcoes_ids = [str(op) for op in (linha.get("opcoes") or [])]
            opcoes_detalhes: list[dict[str, Any]] = []
            soma_opcoes: int = 0

            for op_id in opcoes_ids:
                op_model = opcoes_db.get(op_id)
                if not op_model:
                    raise OrderPricingEngineError(
                        mensagem=_(f"A opção com ID '{op_id}' não existe no catálogo (RN-014)."),
                        codigo_regra="RN-014",
                    )
                preco_adicional: int = int(getattr(op_model, "preco_adicional", 0) or 0)
                soma_opcoes += preco_adicional
                opcoes_detalhes.append({
                    "opcao_id": str(op_model.id),
                    "nome": getattr(op_model, "nome", f"Opção {op_model.id}"),
                    "preco_adicional": preco_adicional,
                })

            preco_unitario_com_opcoes: int = preco_base_item + soma_opcoes
            subtotal_linha: int = preco_unitario_com_opcoes * qtd

            subtotal += subtotal_linha
            total_unidades += qtd

            linhas_discriminadas.append({
                "item_id": str(item_model.id),
                "nome": item_model.nome,
                "preco_base": preco_base_item,
                "opcoes": opcoes_detalhes,
                "soma_opcoes_unitario": soma_opcoes,
                "preco_unitario_total": preco_unitario_com_opcoes,
                "quantidade": qtd,
                "subtotal_linha": subtotal_linha,
                "notas": linha.get("notas", "") or "",
            })

        # ---------------------------------------------------------------------
        # 3. Validação de Pedido Mínimo (RN-041)
        # ---------------------------------------------------------------------
        # Parâmetro de pedido mínimo da loja (Secção 8, default: 2.000 Kz = 200_000 un. mínimas)
        pedido_minimo_loja: int = getattr(loja, "pedido_minimo", None) or cls.DEFAULT_PEDIDO_MINIMO_LOJA

        taxa_pequeno_pedido: int = 0
        if subtotal < pedido_minimo_loja:
            # Calcula o suplemento correspondente à diferença para o valor mínimo (RN-041)
            taxa_pequeno_pedido = pedido_minimo_loja - subtotal

        # ---------------------------------------------------------------------
        # 4. Taxa de Entrega Dinâmica com PostGIS (RN-051, RN-052)
        # ---------------------------------------------------------------------
        morada = None
        if morada_id:
            try:
                morada = Morada.objects.get(pk=morada_id, utilizador=utilizador)
            except (Morada.DoesNotExist, ValueError):
                pass

        if not morada:
            morada = utilizador.moradas.order_by("-id").first()

        distancia_metros: float = 0.0
        distancia_km: Decimal = Decimal("0.00")

        ponto_loja = loja.geolocalizacao
        ponto_entrega = morada.geolocalizacao if morada else None

        if ponto_loja and ponto_entrega:
            # Distância geodésica PostGIS (SRID 4326 em WGS84 multiplicada por ~111319.49 m/grau)
            dist_graus = ponto_loja.distance(ponto_entrega)
            distancia_metros = float(dist_graus * 111319.49)
            distancia_km = (Decimal(str(distancia_metros)) / Decimal("1000.0")).quantize(
                Decimal("0.01"), rounding=ROUND_HALF_UP
            )

        # Fórmula linear: base + (preco_por_km * distancia_efetiva)
        taxa_entrega_base_config = cls.DEFAULT_TAXA_ENTREGA_BASE
        preco_km_config = cls.DEFAULT_PRECO_POR_KM

        custo_km_inteiro = cls._arredondar_inteiro(Decimal(preco_km_config) * distancia_km)
        taxa_entrega_base_calculada: int = taxa_entrega_base_config + custo_km_inteiro

        # Se a loja oferecer entrega grátis (RN-028)
        if getattr(loja, "is_entrega_gratis", False):
            taxa_entrega_base_calculada = 0

        # Multiplicador dinâmico de sobrecarga / Surge Pricing (RN-030, RN-052)
        fator_dinamico = Decimal("1.00")
        fator_em_cache = cache.get(f"logistics:surge_factor:{loja.id}")

        if fator_dinamico_input is not None:
            try:
                fator_dinamico = Decimal(str(fator_dinamico_input))
            except Exception:
                pass
        elif fator_em_cache is not None:
            try:
                fator_dinamico = Decimal(str(fator_em_cache))
            except Exception:
                pass

        # Garante teto de 1.00x a 2.00x (RN-052)
        fator_dinamico = max(
            cls.SURGE_MULTIPLIER_MINIMO,
            min(cls.SURGE_MULTIPLIER_MAXIMO, fator_dinamico)
        ).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

        taxa_entrega_final = cls._arredondar_inteiro(Decimal(taxa_entrega_base_calculada) * fator_dinamico)
        acrescimo_dinamico = taxa_entrega_final - taxa_entrega_base_calculada

        # ---------------------------------------------------------------------
        # 5. Taxa de Serviço (RN-053)
        # ---------------------------------------------------------------------
        # 5% sobre o subtotal, com limites de teto mínimo (100 Kz) e máximo (500 Kz)
        taxa_servico_bruta_decimal = Decimal(subtotal) * (cls.TAXA_SERVICO_PERCENTAGEM / Decimal("100"))
        taxa_servico_bruta = cls._arredondar_inteiro(taxa_servico_bruta_decimal)

        taxa_servico_minima = cls.DEFAULT_TAXA_SERVICO_MINIMA
        taxa_servico_maxima = cls.DEFAULT_TAXA_SERVICO_MAXIMA
        taxa_servico_final = max(taxa_servico_minima, min(taxa_servico_maxima, taxa_servico_bruta))

        # ---------------------------------------------------------------------
        # 6. Descontos de Cupão e Repartição do Financiador (RN-055, RN-056)
        # ---------------------------------------------------------------------
        desconto_total: int = 0
        detalhes_cupao: dict[str, Any] | None = None

        if cupao_codigo and str(cupao_codigo).strip():
            codigo_limpo = str(cupao_codigo).strip().upper()
            cupao = CupaoDesconto.objects.filter(codigo=codigo_limpo).first()

            if not cupao:
                raise OrderPricingEngineError(
                    mensagem=_(f"O cupão de desconto '{codigo_limpo}' não existe (RN-056)."),
                    codigo_regra="RN-056",
                )

            # Validação temporal
            if not (cupao.validade_inicio <= agora <= cupao.validade_fim):
                raise OrderPricingEngineError(
                    mensagem=_(f"O cupão '{codigo_limpo}' expirou ou ainda não iniciou a sua vigência (RN-056)."),
                    codigo_regra="RN-056",
                )

            # Validação de montante mínimo de pedido
            if subtotal < int(cupao.montante_minimo_pedido):
                minimo_kz = cupao.montante_minimo_pedido / 100
                raise OrderPricingEngineError(
                    mensagem=_(
                        f"O cupão '{codigo_limpo}' exige um subtotal mínimo de {minimo_kz:,.2f} Kz (RN-056)."
                    ),
                    codigo_regra="RN-056",
                    detalhes={
                        "subtotal_atual": subtotal,
                        "montante_minimo": int(cupao.montante_minimo_pedido),
                    },
                )

            # Cálculo da dedução (Percentual ou Fixo)
            if cupao.tipo_desconto == CupaoDesconto.TipoDesconto.PERCENTAGEM:
                percentagem = Decimal(str(cupao.valor))
                desconto_calculado = cls._arredondar_inteiro(Decimal(subtotal) * (percentagem / Decimal("100")))
                desconto_total = min(subtotal, desconto_calculado)
            else:
                # Fixo em unidades mínimas inteiras
                desconto_total = min(subtotal, int(cupao.valor))

            # Repartição do Financiamento (RN-055)
            custo_plataforma = 0
            custo_parceiro = 0
            if cupao.financiador == CupaoDesconto.FinanciadorCupao.PLATAFORMA:
                custo_plataforma = desconto_total
            elif cupao.financiador == CupaoDesconto.FinanciadorCupao.PARCEIRO:
                custo_parceiro = desconto_total
            else:
                # PARTILHADO (50% / 50% com arredondamento determinístico)
                custo_parceiro = cls._arredondar_inteiro(Decimal(desconto_total) / Decimal("2"))
                custo_plataforma = desconto_total - custo_parceiro

            detalhes_cupao = {
                "cupao_id": str(cupao.id),
                "codigo": cupao.codigo,
                "tipo_desconto": cupao.tipo_desconto,
                "valor_configurado": int(cupao.valor),
                "desconto_aplicado": desconto_total,
                "financiador": cupao.financiador,
                "reparticao_financiamento": {
                    "suportado_pela_plataforma": custo_plataforma,
                    "suportado_pelo_parceiro": custo_parceiro,
                },
            }

        # ---------------------------------------------------------------------
        # 7. Total Final (RN-050)
        # Total = Subtotal + Taxa Entrega + Taxa Serviço + Taxa Pequeno Pedido + Gorjeta - Descontos
        # ---------------------------------------------------------------------
        bruto = (
            subtotal
            + taxa_entrega_final
            + taxa_servico_final
            + taxa_pequeno_pedido
            + gorjeta_estafeta
        )
        total_final = max(0, bruto - desconto_total)

        # ---------------------------------------------------------------------
        # 8. Congelamento da Cotação em Redis (RN-043)
        # ---------------------------------------------------------------------
        cotacao_id = str(uuid.uuid4())
        expira_em = agora + timedelta(seconds=cls.COTACAO_TTL_SEGUNDOS)

        # Hash SHA-256 de integridade e não-repúdio do carrinho cotado
        assinatura_hash = cls._gerar_hash_assinatura(
            utilizador_id=str(utilizador.id),
            loja_id=str(loja.id),
            morada_id=str(morada.id) if morada else "",
            subtotal=subtotal,
            total_final=total_final,
            itens=linhas_discriminadas,
        )

        cotacao_payload: dict[str, Any] = {
            "cotacao_id": cotacao_id,
            "id_cotacao": cotacao_id,  # alias para retrocompatibilidade
            "criado_em": agora.isoformat(),
            "expira_em": expira_em.isoformat(),
            "ttl_segundos": cls.COTACAO_TTL_SEGUNDOS,
            "assinatura_hash": assinatura_hash,
            "utilizador": {
                "id": str(utilizador.id),
                "nome": utilizador.nome,
                "telemovel": utilizador.telemovel,
            },
            "loja": {
                "id": str(loja.id),
                "nome": loja.nome,
                "nif": loja.nif,
                "pedido_minimo": pedido_minimo_loja,
            },
            "morada_entrega": {
                "id": str(morada.id) if morada else None,
                "texto_endereco": morada.texto_endereco if morada else "",
                "distancia_metros": int(distancia_metros),
                "distancia_km": str(distancia_km),
            },
            "itens": linhas_discriminadas,
            "discriminacao_financeira": {
                "subtotal": subtotal,
                "taxa_entrega": taxa_entrega_final,
                "taxa_servico": taxa_servico_final,
                "taxa_pequeno_pedido": taxa_pequeno_pedido,
                "gorjeta_estafeta": gorjeta_estafeta,
                "descontos": desconto_total,
                "total_cobrado": total_final,
                "moeda": "KZ",
                "unidade": "centimos",
            },
            "detalhes_taxa_entrega": {
                "taxa_base": taxa_entrega_base_config,
                "preco_por_km": preco_km_config,
                "distancia_km": str(distancia_km),
                "taxa_base_calculada": taxa_entrega_base_calculada,
                "fator_dinamico": str(fator_dinamico),
                "acrescimo_dinamico": acrescimo_dinamico,
                "taxa_entrega_final": taxa_entrega_final,
                "is_entrega_gratis": getattr(loja, "is_entrega_gratis", False),
            },
            "detalhes_taxa_servico": {
                "percentagem_aplicada": str(cls.TAXA_SERVICO_PERCENTAGEM),
                "valor_bruto_calculado": taxa_servico_bruta,
                "teto_minimo": taxa_servico_minima,
                "teto_maximo": taxa_servico_maxima,
                "valor_final": taxa_servico_final,
            },
            "detalhes_cupao": detalhes_cupao,
        }

        # Persistência em cache Redis com TTL imutável de 15 minutos (RN-043)
        chave_redis = cls.CACHE_KEY_PREFIX.format(cotacao_id=cotacao_id)
        cache.set(chave_redis, cotacao_payload, timeout=cls.COTACAO_TTL_SEGUNDOS)

        logger.info(
            "[PRICING_ENGINE] Cotação %s gerada com sucesso para utilizador %s na loja %s: "
            "Subtotal=%d | TaxaEntrega=%d (Surge: %sx) | TaxaServico=%d | TaxaPequenoPedido=%d | "
            "Gorjeta=%d | Desconto=%d => TOTAL=%d (TTL=%ds)",
            cotacao_id,
            utilizador.id,
            loja.id,
            subtotal,
            taxa_entrega_final,
            fator_dinamico,
            taxa_servico_final,
            taxa_pequeno_pedido,
            gorjeta_estafeta,
            desconto_total,
            total_final,
            cls.COTACAO_TTL_SEGUNDOS,
        )

        return cotacao_payload

    @classmethod
    def obter_cotacao_valida(cls, cotacao_id: str, utilizador: CustomUser) -> dict[str, Any]:
        """
        RN-043: Recupera a cotação congelada em Redis, validando que não expirou
        e que pertence ao utilizador requerente.
        """
        if not cotacao_id:
            raise OrderPricingEngineError(
                mensagem=_("Identificador de cotação não fornecido."),
                codigo_regra="RN-043",
            )
        chave_redis = cls.CACHE_KEY_PREFIX.format(cotacao_id=str(cotacao_id))
        cotacao = cache.get(chave_redis)

        if not cotacao:
            raise OrderPricingEngineError(
                mensagem=_(
                    "A cotação de preços expirou (limite de 15 minutos ultrapassado) "
                    "ou não existe. Por favor, recalcule o carrinho (RN-043)."
                ),
                codigo_regra="RN-043",
                detalhes={"cotacao_id": str(cotacao_id)},
            )

        if str(cotacao.get("utilizador", {}).get("id")) != str(utilizador.id):
            raise OrderPricingEngineError(
                mensagem=_("Esta cotação pertence a outro utilizador e não pode ser resgatada."),
                codigo_regra="RN-043",
            )

        return cotacao

    @staticmethod
    def _gerar_hash_assinatura(
        utilizador_id: str,
        loja_id: str,
        morada_id: str,
        subtotal: int,
        total_final: int,
        itens: list[dict[str, Any]],
    ) -> str:
        """Gera um hash SHA-256 determinístico para validação de integridade dos valores."""
        dados = {
            "u": utilizador_id,
            "l": loja_id,
            "m": morada_id,
            "s": subtotal,
            "t": total_final,
            "i": [
                {
                    "id": it["item_id"],
                    "q": it["quantidade"],
                    "p": it["preco_unitario_total"],
                }
                for it in sorted(itens, key=lambda x: x["item_id"])
            ],
        }
        raw = json.dumps(dados, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

