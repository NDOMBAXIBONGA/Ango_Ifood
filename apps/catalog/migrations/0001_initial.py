# Generated manually for catalog initial migration
import decimal
import uuid
from django.conf import settings
import django.contrib.gis.db.models.fields
import django.core.validators
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('accounts', '0002_customuser_tipo_utilizador'),
    ]

    operations = [
        migrations.CreateModel(
            name='ParceiroLoja',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) do parceiro/loja.', primary_key=True, serialize=False, verbose_name='ID da Loja')),
                ('nome', models.CharField(db_index=True, help_text='RN-010: Nome comercial do estabelecimento parceiro.', max_length=150, verbose_name='Nome da Loja')),
                ('nif', models.CharField(db_index=True, help_text='RN-010: Número de Identificação Fiscal único da empresa parceira.', max_length=30, unique=True, verbose_name='NIF')),
                ('morada_texto', models.CharField(help_text='RN-010: Endereço textual completo do estabelecimento comercial.', max_length=255, verbose_name='Morada Física')),
                ('contacto', models.CharField(default='', help_text='RN-010: Telefone/contacto direto do representante ou balcão da loja.', max_length=50, verbose_name='Contacto Operacional')),
                ('dados_bancarios', models.JSONField(default=dict, help_text='RN-010: Estrutura JSON com dados bancários validados (ex.: IBAN, SWIFT, titular) para liquidação.', verbose_name='Dados Bancários')),
                ('licenca_sanitaria', models.CharField(default='', help_text='RN-010: Número ou referência da licença sanitária válida do estabelecimento.', max_length=100, verbose_name='Licença Sanitária')),
                ('alvara', models.CharField(default='', help_text='RN-010: Número ou referência do alvará de funcionamento comercial.', max_length=100, verbose_name='Alvará Comercial')),
                ('geolocalizacao', django.contrib.gis.db.models.fields.PointField(blank=True, geography=True, help_text='RN-010 / RN-025: Ponto geográfico PostGIS (SRID 4326) onde se situa a loja para cálculo de rotas e raio.', null=True, srid=4326, verbose_name='Geolocalização da Loja (PostGIS)')),
                ('raio_entrega_km', models.DecimalField(decimal_places=2, default=decimal.Decimal('7.00'), help_text='RN-025: Raio configurável de cobertura de entrega em quilómetros (ex.: 7.00 km).', max_digits=5, validators=[django.core.validators.MinValueValidator(decimal.Decimal('0.10')), django.core.validators.MaxValueValidator(decimal.Decimal('100.00'))], verbose_name='Raio de Entrega (km)')),
                ('poligono_cobertura', django.contrib.gis.db.models.fields.PolygonField(blank=True, geography=True, help_text='RN-025: Polígono geográfico PostGIS (SRID 4326) que delimita a área exata de entrega da loja.', null=True, srid=4326, verbose_name='Polígono de Cobertura (PostGIS)')),
                ('estado', models.CharField(choices=[('PENDENTE', 'Pendente'), ('ATIVO', 'Ativo'), ('PAUSADO', 'Pausado'), ('SUSPENSO', 'Suspenso')], db_index=True, default='PENDENTE', help_text='RN-011 / RN-013 / RN-019: Estado operacional (Pendente, Ativo, Pausado, Suspenso).', max_length=15, verbose_name='Estado da Loja')),
                ('comissao_percentagem', models.DecimalField(decimal_places=2, default=decimal.Decimal('20.00'), help_text='RN-054 / Secção 11: Percentagem contratual de comissão sobre vendas (ex.: 15.00 a 30.00%).', max_digits=5, validators=[django.core.validators.MinValueValidator(decimal.Decimal('0.00')), django.core.validators.MaxValueValidator(decimal.Decimal('100.00'))], verbose_name='Comissão da Plataforma (%)')),
                ('score_reputacao', models.DecimalField(db_index=True, decimal_places=2, default=decimal.Decimal('5.00'), help_text='RN-019 / RN-116: Pontuação de qualidade do parceiro calculada com base em aceitação, avaliações e incidentes.', max_digits=3, validators=[django.core.validators.MinValueValidator(decimal.Decimal('0.00')), django.core.validators.MaxValueValidator(decimal.Decimal('5.00'))], verbose_name='Score de Reputação')),
                ('is_patrocinado', models.BooleanField(db_index=True, default=False, help_text='RN-027 / RN-062: Indica se a loja tem campanha ativa de posicionamento patrocinado no topo.', verbose_name='Destaque Patrocinado')),
                ('is_entrega_gratis', models.BooleanField(db_index=True, default=False, help_text='RN-028: Indica se o estabelecimento tem campanha ou condição de entrega grátis ativa.', verbose_name='Entrega Gratuita')),
                ('proprietario', models.ForeignKey(blank=True, help_text='RN-010: Conta de utilizador representante legal/gestor da loja parceira.', null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='lojas_geridas', to=settings.AUTH_USER_MODEL, verbose_name='Representante / Proprietário')),
            ],
            options={
                'verbose_name': 'Parceiro / Loja',
                'verbose_name_plural': 'Parceiros / Lojas',
                'db_table': 'catalog_parceiro_loja',
                'ordering': ['-score_reputacao', 'nome'],
            },
        ),
        migrations.CreateModel(
            name='CategoriaItem',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='RN-014: Identificador único universal (UUID v4) da categoria do menu.', primary_key=True, serialize=False, verbose_name='ID da Categoria')),
                ('nome', models.CharField(help_text="RN-014: Designação da categoria no menu (ex.: 'Hambúrgueres Artesanais').", max_length=120, verbose_name='Nome da Categoria')),
                ('ordem_exibicao', models.PositiveIntegerField(db_index=True, default=0, help_text='RN-014: Ordem numérica crescente em que a categoria surge na aplicação.', verbose_name='Ordem de Exibição')),
                ('loja', models.ForeignKey(help_text='RN-014: Loja à qual pertence esta categoria de itens.', on_delete=django.db.models.deletion.CASCADE, related_name='categorias', to='catalog.parceiroloja', verbose_name='Loja')),
            ],
            options={
                'verbose_name': 'Categoria de Item',
                'verbose_name_plural': 'Categorias de Itens',
                'db_table': 'catalog_categoria_item',
                'ordering': ['loja', 'ordem_exibicao', 'nome'],
            },
        ),
        migrations.CreateModel(
            name='HorarioFuncionamento',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('dia_semana', models.PositiveSmallIntegerField(choices=[(0, 'Segunda-feira'), (1, 'Terça-feira'), (2, 'Quarta-feira'), (3, 'Quinta-feira'), (4, 'Sexta-feira'), (5, 'Sábado'), (6, 'Domingo')], db_index=True, help_text='RN-012: Dia da semana (0 = Segunda-feira a 6 = Domingo).', validators=[django.core.validators.MinValueValidator(0), django.core.validators.MaxValueValidator(6)], verbose_name='Dia da Semana')),
                ('hora_abertura', models.TimeField(help_text='RN-012: Hora de abertura da loja neste turno.', verbose_name='Hora de Abertura')),
                ('hora_fecho', models.TimeField(help_text='RN-012: Hora de encerramento da loja neste turno.', verbose_name='Hora de Fecho')),
                ('is_pausa_temporaria', models.BooleanField(default=False, help_text='RN-013: Indica se o parceiro pausou temporariamente a receção de pedidos neste horário.', verbose_name='Em Pausa Temporária')),
                ('reativacao_automatica_em', models.DateTimeField(blank=True, help_text='RN-013: Data e hora exatas em que a pausa temporária expira e a loja é reativada automaticamente.', null=True, verbose_name='Reativação Automática Em')),
                ('loja', models.ForeignKey(help_text='RN-012: Parceiro/Loja a que se aplica este horário de funcionamento.', on_delete=django.db.models.deletion.CASCADE, related_name='horarios', to='catalog.parceiroloja', verbose_name='Loja')),
            ],
            options={
                'verbose_name': 'Horário de Funcionamento',
                'verbose_name_plural': 'Horários de Funcionamento',
                'db_table': 'catalog_horario_funcionamento',
                'ordering': ['loja', 'dia_semana', 'hora_abertura'],
            },
        ),
        migrations.CreateModel(
            name='ItemMenu',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='RN-014: Identificador único universal (UUID v4) do item de menu.', primary_key=True, serialize=False, verbose_name='ID do Item')),
                ('nome', models.CharField(db_index=True, help_text='RN-014: Nome do produto ou prato exibido aos clientes.', max_length=150, verbose_name='Nome do Item')),
                ('descricao', models.TextField(blank=True, default='', help_text='RN-014: Descrição comercial e composição detalhada do item.', verbose_name='Descrição')),
                ('preco', models.PositiveBigIntegerField(help_text='RN-014 / RN-016 / RN-059: Preço final de venda expresso em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Preço (Unidades Mínimas Inteiras)')),
                ('imagem_url', models.URLField(blank=True, default='', help_text='RN-014: Endereço URL da imagem do produto no CDN/Storage.', max_length=500, verbose_name='URL da Imagem')),
                ('alergenos', models.JSONField(blank=True, default=list, help_text='RN-014: Lista JSON de alergénios presentes no item.', verbose_name='Alergénios')),
                ('is_disponivel', models.BooleanField(db_index=True, default=True, help_text='RN-014 / RN-015: Se False, o item surge indisponível.', verbose_name='Está Disponível')),
                ('categoria', models.ForeignKey(blank=True, help_text='RN-014: Categoria do menu à qual pertence este item.', null=True, on_delete=django.db.models.deletion.CASCADE, related_name='itens_categoria', to='catalog.categoriaitem', verbose_name='Categoria')),
                ('loja', models.ForeignKey(blank=True, help_text='Secção 11 / RN-014: Loja à qual este item pertence diretamente.', null=True, on_delete=django.db.models.deletion.CASCADE, related_name='itens', to='catalog.parceiroloja', verbose_name='Loja')),
            ],
            options={
                'verbose_name': 'Item do Menu',
                'verbose_name_plural': 'Itens do Menu',
                'db_table': 'catalog_item_menu',
                'ordering': ['categoria', 'nome'],
            },
        ),
        migrations.CreateModel(
            name='GrupoOpcao',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='RN-014: Identificador único universal (UUID v4) do grupo de opções.', primary_key=True, serialize=False, verbose_name='ID do Grupo de Opção')),
                ('nome', models.CharField(help_text='RN-014: Título do grupo de opções apresentado ao cliente.', max_length=120, verbose_name='Nome do Grupo')),
                ('is_obrigatorio', models.BooleanField(default=False, help_text='RN-014: Indica se a seleção neste grupo é obrigatória.', verbose_name='É Obrigatório')),
                ('minimo_escolhas', models.PositiveSmallIntegerField(default=0, help_text='RN-014: Quantidade mínima de opções que devem ser selecionadas.', verbose_name='Mínimo de Escolhas')),
                ('maximo_escolhas', models.PositiveSmallIntegerField(default=1, help_text='RN-014: Quantidade máxima de opções permitidas.', validators=[django.core.validators.MinValueValidator(1)], verbose_name='Máximo de Escolhas')),
                ('item', models.ForeignKey(help_text='RN-014: Item do menu que disponibiliza este grupo de personalização.', on_delete=django.db.models.deletion.CASCADE, related_name='grupos_opcoes', to='catalog.itemmenu', verbose_name='Item do Menu')),
            ],
            options={
                'verbose_name': 'Grupo de Opção',
                'verbose_name_plural': 'Grupos de Opções',
                'db_table': 'catalog_grupo_opcao',
                'ordering': ['item', 'nome'],
            },
        ),
        migrations.CreateModel(
            name='OpcaoItem',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='RN-014: Identificador único universal (UUID v4) da opção de item.', primary_key=True, serialize=False, verbose_name='ID da Opção')),
                ('tipo_grupo', models.CharField(default='Opcional', help_text="RN-014: Classificação da opção (ex.: 'Obrigatório', 'Opcional').", max_length=50, verbose_name='Tipo de Grupo')),
                ('nome', models.CharField(help_text='RN-014: Nome descritivo da opção ou extra.', max_length=120, verbose_name='Nome da Opção')),
                ('preco_adicional', models.PositiveBigIntegerField(default=0, help_text='RN-014 / RN-016 / RN-059: Acréscimo ao preço base do item em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Preço Adicional (Unidades Mínimas Inteiras)')),
                ('is_disponivel', models.BooleanField(db_index=True, default=True, help_text='RN-014 / RN-015: Indica se a opção está atualmente disponível para seleção.', verbose_name='Está Disponível')),
                ('grupo', models.ForeignKey(blank=True, help_text='RN-014: Grupo de opções no qual esta opção está inserida.', null=True, on_delete=django.db.models.deletion.CASCADE, related_name='opcoes_grupo', to='catalog.grupoopcao', verbose_name='Grupo de Opção')),
                ('item', models.ForeignKey(blank=True, help_text='Secção 11 / RN-014: Item de menu ao qual esta opção pertence.', null=True, on_delete=django.db.models.deletion.CASCADE, related_name='opcoes', to='catalog.itemmenu', verbose_name='Item do Menu')),
            ],
            options={
                'verbose_name': 'Opção de Item',
                'verbose_name_plural': 'Opções de Itens',
                'db_table': 'catalog_opcao_item',
                'ordering': ['grupo', 'nome'],
            },
        ),
        migrations.AddIndex(
            model_name='parceiroloja',
            index=models.Index(fields=['estado', '-score_reputacao'], name='idx_loja_estado_score'),
        ),
        migrations.AddIndex(
            model_name='parceiroloja',
            index=models.Index(fields=['nif'], name='idx_loja_nif'),
        ),
        migrations.AddConstraint(
            model_name='categoriaitem',
            constraint=models.UniqueConstraint(fields=('loja', 'nome'), name='uq_categoria_loja_nome'),
        ),
        migrations.AddIndex(
            model_name='horariofuncionamento',
            index=models.Index(fields=['loja', 'dia_semana'], name='idx_horario_loja_dia'),
        ),
        migrations.AddIndex(
            model_name='itemmenu',
            index=models.Index(fields=['categoria', 'is_disponivel'], name='idx_item_cat_disp'),
        ),
    ]
