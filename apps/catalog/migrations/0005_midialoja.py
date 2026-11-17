import uuid
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0004_delete_all_menu_items_vitrine"),
    ]

    operations = [
        migrations.CreateModel(
            name="MidiaLoja",
            fields=[
                (
                    "id",
                    models.UUIDField(
                        default=uuid.uuid4,
                        editable=False,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID da Mídia",
                    ),
                ),
                (
                    "tipo",
                    models.CharField(
                        choices=[("IMAGEM", "Imagem"), ("VIDEO", "Vídeo")],
                        db_index=True,
                        default="IMAGEM",
                        max_length=10,
                        verbose_name="Tipo de Mídia",
                    ),
                ),
                (
                    "nome_arquivo",
                    models.CharField(
                        db_index=True,
                        help_text="Nome do ficheiro no disco/storage (ex.: uuid.mp4 ou uuid.jpg).",
                        max_length=255,
                        verbose_name="Nome do Ficheiro",
                    ),
                ),
                (
                    "content_type",
                    models.CharField(
                        default="application/octet-stream",
                        max_length=100,
                        verbose_name="Content Type MIME",
                    ),
                ),
                (
                    "tamanho_bytes",
                    models.PositiveBigIntegerField(
                        default=0,
                        verbose_name="Tamanho em Bytes",
                    ),
                ),
                (
                    "url",
                    models.URLField(
                        blank=True,
                        default="",
                        max_length=500,
                        verbose_name="URL de Acesso",
                    ),
                ),
                (
                    "legenda",
                    models.CharField(
                        blank=True,
                        default="",
                        max_length=255,
                        verbose_name="Legenda ou Título",
                    ),
                ),
                (
                    "dados_binarios",
                    models.BinaryField(
                        blank=True,
                        help_text="Backup binário (PostgreSQL bytea) para auto-recuperação do disco efêmero do Render.",
                        null=True,
                        verbose_name="Conteúdo Binário Persistente",
                    ),
                ),
                (
                    "criado_em",
                    models.DateTimeField(
                        auto_now_add=True,
                        db_index=True,
                        verbose_name="Criado em",
                    ),
                ),
                (
                    "atualizado_em",
                    models.DateTimeField(
                        auto_now=True,
                        verbose_name="Atualizado em",
                    ),
                ),
                (
                    "loja",
                    models.ForeignKey(
                        help_text="Loja parceira proprietária deste ficheiro multimédia.",
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="midias",
                        to="catalog.parceiroloja",
                        verbose_name="Loja",
                    ),
                ),
            ],
            options={
                "verbose_name": "Mídia da Loja",
                "verbose_name_plural": "Mídias das Lojas",
                "db_table": "catalog_midia_loja",
                "ordering": ["-criado_em"],
            },
        ),
    ]
