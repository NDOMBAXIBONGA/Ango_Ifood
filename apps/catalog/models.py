"""
Modelos de dados da aplicação 'catalog' (Parceiros, Lojas, Horários, Menus e Opções).
Implementa as regras de negócio RN-010 a RN-020, RN-025, RN-054, RN-059 e Secção 11 do documento funcional:
- RN-010: Onboarding completo do parceiro (NIF único, morada, contacto, dados bancários, licença sanitária e alvará).
- RN-011: Fluxo de aprovação documental (estado inicial Pendente até validação por Operações).
- RN-012: Horário de funcionamento por dia da semana (0-6) e validação de loja aberta/fechada.
- RN-013: Pausa temporária com timestamp de reativação automática no fim do prazo.
- RN-014: Estrutura de catálogo com Categorias, Itens, Alergénios e Grupos de Opções (obrigatórias/opcionais, mín/máx).
- RN-015: Controlo de disponibilidade imediata de itens e opções de menu.
- RN-016 / RN-059: Preços finais em unidades mínimas inteiras (Cêntimos / Kwanza convertido) sem custos escondidos.
- RN-019: Score de qualidade e reputação do parceiro (impacta visibilidade e possível suspensão).
- RN-020: Rastreabilidade de alterações ao catálogo.
- RN-025: Zonas de cobertura de entrega georreferenciadas em PostGIS (PointField e PolygonField com SRID 4326 + raio km).
"""
import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any

from django.conf import settings
from django.contrib.gis.db import models as gis_models
from django.core.exceptions import ValidationError
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _


class ParceiroLoja(gis_models.Model):
    """
    Entidade 1: Representa um Parceiro / Loja comercial na plataforma (Secção 11).
    Inclui dados fiscais/legais de onboarding (RN-010), estado operacional (RN-011, RN-013, RN-019),
    cobertura espacial PostGIS (RN-025), comissão contratual (RN-054) e reputação (RN-019).
    """

    class EstadoLoja(models.TextChoices):
        """Estados operacionais do parceiro na plataforma (RN-011, RN-013, RN-019)."""

        PENDENTE = "PENDENTE", _("Pendente")
        ATIVO = "ATIVO", _("Ativo")
        PAUSADO = "PAUSADO", _("Pausado")
        SUSPENSO = "SUSPENSO", _("Suspenso")

    # Secção 11: Identificador primário UUID v4
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Loja"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do parceiro/loja."),
    )

    # RN-010: Utilizador representante/proprietário do parceiro comercial
    proprietario = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="lojas_geridas",
        verbose_name=_("Representante / Proprietário"),
        help_text=_("RN-010: Conta de utilizador representante legal/gestor da loja parceira."),
    )

    # RN-010: Nome comercial da loja exibido no catálogo
    nome = models.CharField(
        max_length=150,
        db_index=True,
        verbose_name=_("Nome da Loja"),
        help_text=_("RN-010: Nome comercial do estabelecimento parceiro."),
    )

    # RN-010: Número de Identificação Fiscal único da entidade comercial
    nif = models.CharField(
        max_length=30,
        unique=True,
        db_index=True,
        verbose_name=_("NIF"),
        help_text=_("RN-010: Número de Identificação Fiscal único da empresa parceira."),
    )

    # RN-010: Endereço físico completo da loja para recolha pelos estafetas e faturação
    morada_texto = models.CharField(
        max_length=255,
        verbose_name=_("Morada Física"),
        help_text=_("RN-010: Endereço textual completo do estabelecimento comercial."),
    )

    # RN-010: Contacto telefónico ou eletrónico operacional da loja
    contacto = models.CharField(
        max_length=50,
        verbose_name=_("Contacto Operacional"),
        help_text=_("RN-010: Telefone/contacto direto do representante ou balcão da loja."),
    )

    # RN-010: Dados bancários estruturados (IBAN, banco, titular) para liquidações (RN-145)
    dados_bancarios = models.JSONField(
        default=dict,
        verbose_name=_("Dados Bancários"),
        help_text=_(
            "RN-010: Estrutura JSON com dados bancários validados (ex.: IBAN, SWIFT, titular) para liquidação."
        ),
    )

    # RN-010: Identificador/referência da licença sanitária obrigatória para segurança alimentar
    licenca_sanitaria = models.CharField(
        max_length=100,
        verbose_name=_("Licença Sanitária"),
        help_text=_("RN-010: Número ou referência da licença sanitária válida do estabelecimento."),
    )

    # RN-010: Identificador/referência do alvará comercial
    alvara = models.CharField(
        max_length=100,
        verbose_name=_("Alvará Comercial"),
        help_text=_("RN-010: Número ou referência do alvará de funcionamento comercial."),
    )

    # RN-010 / RN-025: Coordenadas exatas da loja (Longitude, Latitude) em WGS84 (SRID 4326)
    geolocalizacao = gis_models.PointField(
        srid=4326,
        geography=True,
        spatial_index=True,
        verbose_name=_("Geolocalização da Loja (PostGIS)"),
        help_text=_(
            "RN-010 / RN-025: Ponto geográfico PostGIS (SRID 4326) onde se situa a loja para cálculo de rotas e raio."
        ),
    )

    # RN-025: Raio máximo de entrega em quilómetros (ex.: 7.00 km por defeito na Secção 8)
    raio_entrega_km = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=Decimal("7.00"),
        validators=[MinValueValidator(Decimal("0.10")), MaxValueValidator(Decimal("100.00"))],
        verbose_name=_("Raio de Entrega (km)"),
        help_text=_("RN-025: Raio configurável de cobertura de entrega em quilómetros (ex.: 7.00 km)."),
    )

    # RN-025: Polígono geográfico personalizado de cobertura de entrega em PostGIS (SRID 4326)
    poligono_cobertura = gis_models.PolygonField(
        srid=4326,
        geography=True,
        spatial_index=True,
        null=True,
        blank=True,
        verbose_name=_("Polígono de Cobertura (PostGIS)"),
        help_text=_(
            "RN-025: Polígono geográfico PostGIS (SRID 4326) que delimita a área exata de entrega da loja."
        ),
    )

    # RN-011 / RN-013 / RN-019: Estado da loja (inicia Pendente até aprovação documental por Operações)
    estado = models.CharField(
        max_length=15,
        choices=EstadoLoja.choices,
        default=EstadoLoja.PENDENTE,
        db_index=True,
        verbose_name=_("Estado da Loja"),
        help_text=_(
            "RN-011 / RN-013 / RN-019: Estado operacional (Pendente, Ativo, Pausado, Suspenso)."
        ),
    )

    # RN-054 / Secção 11: Percentagem de comissão cobrada pela plataforma sobre o subtotal líquido
    comissao_percentagem = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=Decimal("20.00"),
        validators=[MinValueValidator(Decimal("0.00")), MaxValueValidator(Decimal("100.00"))],
        verbose_name=_("Comissão da Plataforma (%)"),
        help_text=_(
            "RN-054 / Secção 11: Percentagem contratual de comissão sobre vendas (ex.: 15.00 a 30.00%)."
        ),
    )

    # RN-019 / RN-116: Score de qualidade e reputação do parceiro (escala 0.00 a 5.00)
    score_reputacao = models.DecimalField(
        max_digits=3,
        decimal_places=2,
        default=Decimal("5.00"),
        validators=[MinValueValidator(Decimal("0.00")), MaxValueValidator(Decimal("5.00"))],
        db_index=True,
        verbose_name=_("Score de Reputação"),
        help_text=_(
            "RN-019 / RN-116: Pontuação de qualidade do parceiro calculada com base em aceitação, avaliações e incidentes."
        ),
    )

    # RN-027 / RN-062: Flag de posicionamento patrocinado (exige indicação transparente de publicidade ao cliente)
    is_patrocinado = models.BooleanField(
        default=False,
        db_index=True,
        verbose_name=_("Destaque Patrocinado"),
        help_text=_(
            "RN-027 / RN-062: Indica se a loja tem campanha ativa de posicionamento patrocinado no topo."
        ),
    )

    # RN-028: Indica se a loja oferece taxa de entrega gratuita
    is_entrega_gratis = models.BooleanField(
        default=False,
        db_index=True,
        verbose_name=_("Entrega Gratuita"),
        help_text=_(
            "RN-028: Indica se o estabelecimento tem campanha ou condição de entrega grátis ativa."
        ),
    )

    class Meta:
        db_table = "catalog_parceiro_loja"
        verbose_name = _("Parceiro / Loja")
        verbose_name_plural = _("Parceiros / Lojas")
        ordering = ["-score_reputacao", "nome"]
        indexes = [
            models.Index(fields=["estado", "-score_reputacao"], name="idx_loja_estado_score"),
            models.Index(fields=["nif"], name="idx_loja_nif"),
        ]

    def __str__(self) -> str:
        return f"{self.nome} (NIF: {self.nif}) [{self.estado}]"

    def is_loja_aberta(self, data_hora_atual: datetime | None = None) -> bool:
        """
        RN-011, RN-012, RN-013: Valida se a loja se encontra aberta e apta a receber pedidos
        imediatos na `data_hora_atual` fornecida (ou no momento atual se omitida).

        Regras verificadas:
        1. O estado da loja não pode ser PENDENTE nem SUSPENSO (RN-011, RN-019).
        2. Se o estado da loja for PAUSADO, só é considerada aberta caso exista um horário com
           `reativacao_automatica_em` já expirado ( <= data_hora_atual ), reativando o estado (RN-013).
        3. Deve existir pelo menos um `HorarioFuncionamento` para o `dia_semana` correspondente (0=Segunda .. 6=Domingo)
           cujo intervalo `[hora_abertura, hora_fecho]` contenha a hora atual (suportando horários noturnos que
           atravessam a meia-noite).
        4. O turno ativo não pode estar em `is_pausa_temporaria=True` com `reativacao_automatica_em` no futuro (RN-013).
        """
        if data_hora_atual is None:
            data_hora_atual = timezone.now()

        if timezone.is_aware(data_hora_atual):
            data_hora_local = timezone.localtime(data_hora_atual)
        else:
            data_hora_local = data_hora_atual

        # 1. Lojas suspensas nunca estão abertas (RN-011, RN-019)
        if self.estado == self.EstadoLoja.SUSPENSO:
            return False

        # Se a loja não possui horários cadastrados mas está ativa/pendente, considera aberta por padrão
        if not self.horarios.exists():
            return True

        dia_atual = data_hora_local.weekday()  # 0 (Segunda-feira) a 6 (Domingo)
        dia_anterior = (dia_atual - 1) % 7
        hora_atual = data_hora_local.time()

        # Consulta todos os horários do dia atual e do dia anterior (para turnos que passam da meia-noite)
        horarios = list(
            self.horarios.filter(dia_semana__in=[dia_atual, dia_anterior])
        )

        # 2. Se a loja está com estado global PAUSADO, verifica se já passou o prazo de reativação automática (RN-013)
        if self.estado == self.EstadoLoja.PAUSADO:
            pausas_ativas = [
                h for h in horarios
                if h.is_pausa_temporaria
                and (h.reativacao_automatica_em is None or h.reativacao_automatica_em > data_hora_atual)
            ]
            espelho_reativado = any(
                h.is_pausa_temporaria
                and h.reativacao_automatica_em is not None
                and h.reativacao_automatica_em <= data_hora_atual
                for h in horarios
            )
            if pausas_ativas or not espelho_reativado:
                return False

            # Reativa automaticamente a loja após o término do prazo da pausa temporária (RN-013)
            self.estado = self.EstadoLoja.ATIVO
            self.save(update_fields=["estado"])

        # 3. Avalia se algum turno cobre a hora atual e não está em pausa temporária ativa (RN-012, RN-013)
        for horario in horarios:
            dentro_do_turno = False

            if horario.dia_semana == dia_atual:
                if horario.hora_abertura <= horario.hora_fecho:
                    # Turno diurno normal (ex.: 09:00 às 22:00)
                    dentro_do_turno = horario.hora_abertura <= hora_atual <= horario.hora_fecho
                else:
                    # Turno noturno que inicia hoje e fecha após a meia-noite (ex.: 18:00 às 02:00)
                    dentro_do_turno = hora_atual >= horario.hora_abertura
            elif horario.dia_semana == dia_anterior and horario.hora_abertura > horario.hora_fecho:
                # Prolongamento na madrugada do turno iniciado no dia anterior (ex.: até às 02:00)
                dentro_do_turno = hora_atual <= horario.hora_fecho

            if not dentro_do_turno:
                continue

            # 4. Verifica se o turno tem pausa temporária ativa (RN-013)
            if horario.is_pausa_temporaria:
                if (
                    horario.reativacao_automatica_em is not None
                    and data_hora_atual >= horario.reativacao_automatica_em
                ):
                    # Prazo da pausa expirou: desativa flag de pausa automaticamente (RN-013)
                    horario.is_pausa_temporaria = False
                    horario.reativacao_automatica_em = None
                    horario.save(update_fields=["is_pausa_temporaria", "reativacao_automatica_em"])
                    return True
                continue

            return True

        return False


class HorarioFuncionamento(models.Model):
    """
    Entidade 2: Define os períodos de abertura e fecho por dia da semana para cada loja,
    bem como o controlo de pausas temporárias com reativação automática (RN-012, RN-013).
    """

    class DiaSemana(models.IntegerChoices):
        """Dias da semana compatíveis com `datetime.weekday()` (0=Segunda a 6=Domingo) (RN-012)."""

        SEGUNDA = 0, _("Segunda-feira")
        TERCA = 1, _("Terça-feira")
        QUARTA = 2, _("Quarta-feira")
        QUINTA = 3, _("Quinta-feira")
        SEXTA = 4, _("Sexta-feira")
        SABADO = 5, _("Sábado")
        DOMINGO = 6, _("Domingo")

    # RN-012: Loja à qual pertence este turno de horário
    loja = models.ForeignKey(
        ParceiroLoja,
        on_delete=models.CASCADE,
        related_name="horarios",
        verbose_name=_("Loja"),
        help_text=_("RN-012: Parceiro/Loja a que se aplica este horário de funcionamento."),
    )

    # RN-012: Dia da semana de 0 (Segunda-feira) a 6 (Domingo)
    dia_semana = models.PositiveSmallIntegerField(
        choices=DiaSemana.choices,
        validators=[MinValueValidator(0), MaxValueValidator(6)],
        db_index=True,
        verbose_name=_("Dia da Semana"),
        help_text=_("RN-012: Dia da semana (0 = Segunda-feira a 6 = Domingo)."),
    )

    # RN-012: Hora de início de receção de pedidos no turno
    hora_abertura = models.TimeField(
        verbose_name=_("Hora de Abertura"),
        help_text=_("RN-012: Hora de abertura da loja neste turno."),
    )

    # RN-012: Hora limite de fecho do turno
    hora_fecho = models.TimeField(
        verbose_name=_("Hora de Fecho"),
        help_text=_("RN-012: Hora de encerramento da loja neste turno."),
    )

    # RN-013: Indica se a loja ativou uma pausa temporária (ex.: sobrecarga de cozinha ou falta de stock)
    is_pausa_temporaria = models.BooleanField(
        default=False,
        verbose_name=_("Em Pausa Temporária"),
        help_text=_(
            "RN-013: Indica se o parceiro pausou temporariamente a receção de pedidos neste horário."
        ),
    )

    # RN-013: Data/hora em que a pausa temporária termina e a loja reabre automaticamente
    reativacao_automatica_em = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("Reativação Automática Em"),
        help_text=_(
            "RN-013: Data e hora exatas em que a pausa temporária expira e a loja é reativada automaticamente."
        ),
    )

    class Meta:
        db_table = "catalog_horario_funcionamento"
        verbose_name = _("Horário de Funcionamento")
        verbose_name_plural = _("Horários de Funcionamento")
        ordering = ["loja", "dia_semana", "hora_abertura"]
        indexes = [
            models.Index(fields=["loja", "dia_semana"], name="idx_horario_loja_dia"),
        ]

    def __str__(self) -> str:
        dia_label = self.get_dia_semana_display()
        pausa_str = " [PAUSA TEMPORÁRIA]" if self.is_pausa_temporaria else ""
        return f"{self.loja.nome} - {dia_label}: {self.hora_abertura:%H:%M} às {self.hora_fecho:%H:%M}{pausa_str}"


class CategoriaItem(models.Model):
    """
    Entidade 3: Agrupador lógico de itens no menu de uma loja (ex.: Entradas, Pratos Principais, Bebidas)
    com ordenação customizável (RN-014).
    """

    # RN-014: Identificador único UUID v4 da categoria
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Categoria"),
        help_text=_("RN-014: Identificador único universal (UUID v4) da categoria do menu."),
    )

    # RN-014: Loja proprietária da categoria de menu
    loja = models.ForeignKey(
        ParceiroLoja,
        on_delete=models.CASCADE,
        related_name="categorias",
        verbose_name=_("Loja"),
        help_text=_("RN-014: Loja à qual pertence esta categoria de itens."),
    )

    # RN-014: Nome visível da categoria
    nome = models.CharField(
        max_length=120,
        verbose_name=_("Nome da Categoria"),
        help_text=_("RN-014: Designação da categoria no menu (ex.: 'Hambúrgueres Artesanais')."),
    )

    # RN-014: Posição relativa para apresentação ordenada na montra da loja
    ordem_exibicao = models.PositiveIntegerField(
        default=0,
        db_index=True,
        verbose_name=_("Ordem de Exibição"),
        help_text=_("RN-014: Ordem numérica crescente em que a categoria surge na aplicação."),
    )

    class Meta:
        db_table = "catalog_categoria_item"
        verbose_name = _("Categoria de Item")
        verbose_name_plural = _("Categorias de Itens")
        ordering = ["loja", "ordem_exibicao", "nome"]
        constraints = [
            models.UniqueConstraint(
                fields=["loja", "nome"],
                name="uq_categoria_loja_nome",
            )
        ]

    def __str__(self) -> str:
        return f"{self.loja.nome} -> {self.nome} (#{self.ordem_exibicao})"

    @property
    def itens(self):
        """Retorna os itens de menu pertencentes a esta categoria."""
        return self.itens_categoria.all()


class ItemMenu(models.Model):
    """
    Entidade 4: Produto ou prato comercializado por uma loja dentro de uma categoria.
    Cumpre as regras RN-014, RN-015, RN-016, RN-020 e RN-059 (valores monetários inteiros).
    """

    # RN-014 / Secção 11: Identificador único UUID v4 do item
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Item"),
        help_text=_("RN-014: Identificador único universal (UUID v4) do item de menu."),
    )

    # Secção 11 / RN-014: Loja à qual o item pertence diretamente (acesso direto loja.itens)
    loja = models.ForeignKey(
        ParceiroLoja,
        on_delete=models.CASCADE,
        related_name="itens",
        null=True,
        blank=True,
        verbose_name=_("Loja"),
        help_text=_("Secção 11 / RN-014: Loja à qual este item pertence diretamente."),
    )

    # RN-014: Categoria onde o item está inserido (opcional para menus com categorias estruturadas)
    categoria = models.ForeignKey(
        CategoriaItem,
        on_delete=models.CASCADE,
        related_name="itens_categoria",
        null=True,
        blank=True,
        verbose_name=_("Categoria"),
        help_text=_("RN-014: Categoria do menu à qual pertence este item."),
    )

    # RN-014: Nome comercial do produto
    nome = models.CharField(
        max_length=150,
        db_index=True,
        verbose_name=_("Nome do Item"),
        help_text=_("RN-014: Nome do produto ou prato exibido aos clientes."),
    )

    # RN-014: Descrição detalhada (ingredientes, peso, modo de confeção)
    descricao = models.TextField(
        blank=True,
        default="",
        verbose_name=_("Descrição"),
        help_text=_("RN-014: Descrição comercial e composição detalhada do item."),
    )

    # RN-014 / RN-016 / RN-059: Preço final com impostos em unidades mínimas inteiras (Cêntimos / Kwanza convertido)
    preco = models.PositiveBigIntegerField(
        validators=[MinValueValidator(0)],
        verbose_name=_("Preço (Unidades Mínimas Inteiras)"),
        help_text=_(
            "RN-014 / RN-016 / RN-059: Preço final de venda (com impostos incluídos) expresso em unidades "
            "mínimas inteiras da moeda (Cêntimos/Kwanza convertido) para evitar erros de vírgula flutuante."
        ),
    )

    # RN-014: URL da fotografia ilustrativa do produto
    imagem_url = models.URLField(
        max_length=500,
        blank=True,
        default="",
        verbose_name=_("URL da Imagem"),
        help_text=_("RN-014: Endereço URL da imagem do produto no CDN/Storage."),
    )

    # RN-014 / Secção 9.3: Lista estruturada de alergénios (ex.: ["gluten", "lactose", "amendoim"])
    alergenos = models.JSONField(
        default=list,
        blank=True,
        verbose_name=_("Alergénios"),
        help_text=_(
            "RN-014: Lista JSON de alergénios presentes no item para segurança alimentar (ex.: ['gluten', 'marisco'])."
        ),
    )

    # RN-014 / RN-015: Controla se o item pode ser adicionado ao carrinho neste momento
    is_disponivel = models.BooleanField(
        default=True,
        db_index=True,
        verbose_name=_("Está Disponível"),
        help_text=_(
            "RN-014 / RN-015: Se False, o item surge indisponível (a cinzento/oculto) e não pode ser adicionado ao carrinho."
        ),
    )

    # Destaque na Página Inicial / Vitrine da Loja
    is_destaque = models.BooleanField(
        default=False,
        db_index=True,
        verbose_name=_("Destaque na Página Inicial"),
        help_text=_(
            "Se True, o artigo surge destacado na secção de 'Pratos Principais em Destaque' da Página Inicial da loja."
        ),
    )

    class Meta:
        db_table = "catalog_item_menu"
        verbose_name = _("Item do Menu")
        verbose_name_plural = _("Itens do Menu")
        ordering = ["categoria", "nome"]
        indexes = [
            models.Index(fields=["categoria", "is_disponivel"], name="idx_item_cat_disp"),
            models.Index(fields=["loja", "is_destaque"], name="idx_item_loja_dest"),
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        """RN-014: Garante que `loja` é sincronizada a partir de `categoria.loja` se não fornecida explicitamente."""
        if self.loja is None and self.categoria and hasattr(self.categoria, "loja"):
            self.loja = self.categoria.loja
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        estado = "Disponível" if self.is_disponivel else "Indisponível"
        return f"{self.nome} ({self.preco}) [{estado}]"


class GrupoOpcao(models.Model):
    """
    Entidade 5: Grupo de personalização ou complementos de um ItemMenu (ex.: 'Escolha o Ponto da Carne',
    'Extras', 'Acompanhamentos') com regras de cardinalidade mínima e máxima (RN-014).
    """

    # RN-014: Identificador único UUID v4 do grupo de opções
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Grupo de Opção"),
        help_text=_("RN-014: Identificador único universal (UUID v4) do grupo de opções."),
    )

    # RN-014: Item de menu ao qual este grupo de opções está associado
    item = models.ForeignKey(
        ItemMenu,
        on_delete=models.CASCADE,
        related_name="grupos_opcoes",
        verbose_name=_("Item do Menu"),
        help_text=_("RN-014: Item do menu que disponibiliza este grupo de personalização."),
    )

    # RN-014: Nome do grupo de opções (ex.: 'Escolha o Molho', 'Adicionais')
    nome = models.CharField(
        max_length=120,
        verbose_name=_("Nome do Grupo"),
        help_text=_("RN-014: Título do grupo de opções apresentado ao cliente."),
    )

    # RN-014: Define se o cliente é obrigado a escolher pelo menos `minimo_escolhas` neste grupo
    is_obrigatorio = models.BooleanField(
        default=False,
        verbose_name=_("É Obrigatório"),
        help_text=_("RN-014: Indica se a seleção neste grupo é obrigatória para adicionar o item ao carrinho."),
    )

    # RN-014: Número mínimo de opções que o cliente tem de selecionar
    minimo_escolhas = models.PositiveSmallIntegerField(
        default=0,
        verbose_name=_("Mínimo de Escolhas"),
        help_text=_("RN-014: Quantidade mínima de opções que devem ser selecionadas neste grupo."),
    )

    # RN-014: Número máximo de opções que o cliente pode selecionar
    maximo_escolhas = models.PositiveSmallIntegerField(
        default=1,
        validators=[MinValueValidator(1)],
        verbose_name=_("Máximo de Escolhas"),
        help_text=_("RN-014: Quantidade máxima de opções permitidas neste grupo."),
    )

    class Meta:
        db_table = "catalog_grupo_opcao"
        verbose_name = _("Grupo de Opção")
        verbose_name_plural = _("Grupos de Opções")
        ordering = ["item", "nome"]

    def clean(self) -> None:
        """
        RN-014: Garante a consistência lógica entre `is_obrigatorio`, `minimo_escolhas` e `maximo_escolhas`.
        """
        super().clean()
        if self.is_obrigatorio and self.minimo_escolhas < 1:
            self.minimo_escolhas = 1
        if self.minimo_escolhas > self.maximo_escolhas:
            raise ValidationError(
                _("RN-014: O 'minimo_escolhas' não pode ser superior ao 'maximo_escolhas'.")
            )

    def __str__(self) -> str:
        obrigatorio_str = "Obrigatório" if self.is_obrigatorio else "Opcional"
        return f"{self.item.nome} -> {self.nome} ({obrigatorio_str}: {self.minimo_escolhas}..{self.maximo_escolhas})"

    @property
    def opcoes(self):
        """Retorna as opções pertencentes a este grupo de opções."""
        return self.opcoes_grupo.all()


class OpcaoItem(models.Model):
    """
    Entidade 6: Opção individual selecionável dentro de um GrupoOpcao (ex.: 'Queijo Cheddar Extra',
    'Sem Cebola'), com suplemento de preço em unidades mínimas inteiras e disponibilidade (RN-014, RN-015, RN-016).
    """

    # RN-014: Identificador único UUID v4 da opção
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Opção"),
        help_text=_("RN-014: Identificador único universal (UUID v4) da opção de item."),
    )

    # Secção 11 / RN-014: Item de menu ao qual esta opção está associada diretamente
    item = models.ForeignKey(
        ItemMenu,
        on_delete=models.CASCADE,
        related_name="opcoes",
        null=True,
        blank=True,
        verbose_name=_("Item do Menu"),
        help_text=_("Secção 11 / RN-014: Item de menu ao qual esta opção pertence."),
    )

    # RN-014: Tipo ou classificação do grupo desta opção ("Obrigatório", "Opcional")
    tipo_grupo = models.CharField(
        max_length=50,
        default="Opcional",
        verbose_name=_("Tipo de Grupo"),
        help_text=_("RN-014: Classificação da opção (ex.: 'Obrigatório', 'Opcional')."),
    )

    # RN-014: Grupo de opções a que pertence esta escolha (opcional quando associada a um grupo)
    grupo = models.ForeignKey(
        GrupoOpcao,
        on_delete=models.CASCADE,
        related_name="opcoes_grupo",
        null=True,
        blank=True,
        verbose_name=_("Grupo de Opção"),
        help_text=_("RN-014: Grupo de opções no qual esta opção está inserida."),
    )

    # RN-014: Designação da opção (ex.: 'Dose Extra de Bacon')
    nome = models.CharField(
        max_length=120,
        verbose_name=_("Nome da Opção"),
        help_text=_("RN-014: Nome descritivo da opção ou extra."),
    )

    # RN-014 / RN-016 / RN-059: Valor adicional em unidades mínimas inteiras (0 se gratuito)
    preco_adicional = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Preço Adicional (Unidades Mínimas Inteiras)"),
        help_text=_(
            "RN-014 / RN-016 / RN-059: Acréscimo ao preço base do item em unidades mínimas inteiras (0 se sem custo)."
        ),
    )

    # RN-014 / RN-015: Controla se esta opção específica está em stock/disponível
    is_disponivel = models.BooleanField(
        default=True,
        db_index=True,
        verbose_name=_("Está Disponível"),
        help_text=_("RN-014 / RN-015: Indica se a opção está atualmente disponível para seleção."),
    )

    class Meta:
        db_table = "catalog_opcao_item"
        verbose_name = _("Opção de Item")
        verbose_name_plural = _("Opções de Itens")
        ordering = ["grupo", "nome"]

    def save(self, *args: Any, **kwargs: Any) -> None:
        """RN-014: Garante que `item` e `tipo_grupo` são sincronizados a partir do `grupo` se não fornecidos."""
        if self.item is None and self.grupo and hasattr(self.grupo, "item"):
            self.item = self.grupo.item
        if (not self.tipo_grupo or self.tipo_grupo == "Opcional") and self.grupo:
            self.tipo_grupo = "Obrigatório" if self.grupo.is_obrigatorio else "Opcional"
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.nome} (+{self.preco_adicional}) [{self.tipo_grupo}]"


class MidiaLoja(models.Model):
    """
    Entidade 7: Armazenamento persistente de Mídia (Imagens e Vídeos) das Lojas Parceiras.
    Resolve a volatilidade do sistema de arquivos efêmero (Render Cloud / Containers)
    mantendo uma cópia binária segura e indexada em PostgreSQL (PostgreSQL Bytea),
    sem sobrecarregar o JSONField de dados bancários da loja.
    """

    class TipoMidia(models.TextChoices):
        IMAGEM = "IMAGEM", _("Imagem")
        VIDEO = "VIDEO", _("Vídeo")

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Mídia"),
    )
    loja = models.ForeignKey(
        ParceiroLoja,
        on_delete=models.CASCADE,
        related_name="midias",
        verbose_name=_("Loja"),
        help_text=_("Loja parceira proprietária deste ficheiro multimédia."),
    )
    tipo = models.CharField(
        max_length=10,
        choices=TipoMidia.choices,
        default=TipoMidia.IMAGEM,
        db_index=True,
        verbose_name=_("Tipo de Mídia"),
    )
    nome_arquivo = models.CharField(
        max_length=255,
        db_index=True,
        verbose_name=_("Nome do Ficheiro"),
        help_text=_("Nome do ficheiro no disco/storage (ex.: uuid.mp4 ou uuid.jpg)."),
    )
    content_type = models.CharField(
        max_length=100,
        default="application/octet-stream",
        verbose_name=_("Content Type MIME"),
    )
    tamanho_bytes = models.PositiveBigIntegerField(
        default=0,
        verbose_name=_("Tamanho em Bytes"),
    )
    url = models.URLField(
        max_length=500,
        blank=True,
        default="",
        verbose_name=_("URL de Acesso"),
    )
    legenda = models.CharField(
        max_length=255,
        blank=True,
        default="",
        verbose_name=_("Legenda ou Título"),
    )
    dados_binarios = models.BinaryField(
        null=True,
        blank=True,
        verbose_name=_("Conteúdo Binário Persistente"),
        help_text=_("Backup binário (PostgreSQL bytea) para auto-recuperação do disco efêmero do Render."),
    )
    criado_em = models.DateTimeField(
        auto_now_add=True,
        db_index=True,
        verbose_name=_("Criado em"),
    )
    atualizado_em = models.DateTimeField(
        auto_now=True,
        verbose_name=_("Atualizado em"),
    )

    class Meta:
        db_table = "catalog_midia_loja"
        ordering = ["-criado_em"]
        verbose_name = _("Mídia da Loja")
        verbose_name_plural = _("Mídias das Lojas")

    def __str__(self) -> str:
        return f"{self.tipo} - {self.nome_arquivo} ({self.loja.nome})"

