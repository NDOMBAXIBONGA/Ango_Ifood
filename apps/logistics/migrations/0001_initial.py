# Generated manually for logistics initial migration
import decimal
import uuid
import apps.logistics.models
from django.conf import settings
import django.contrib.gis.db.models.fields
import django.core.validators
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('orders', '0001_initial'),
        ('accounts', '0002_customuser_tipo_utilizador'),
    ]

    operations = [
        migrations.CreateModel(
            name='Estafeta',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) do estafeta.', primary_key=True, serialize=False, verbose_name='ID do Estafeta')),
                ('tipo_veiculo', models.CharField(choices=[('MOTA', 'Mota'), ('CARRO', 'Carro'), ('BICICLETA', 'Bicicleta')], db_index=True, help_text='RN-082 / RN-084: Veículo utilizado pelo estafeta (Mota, Carro, Bicicleta).', max_length=15, verbose_name='Tipo de Veículo')),
                ('carta_conducao', models.CharField(blank=True, default='', help_text='RN-082: Número da carta de condução (obrigatório para Mota e Carro).', max_length=50, verbose_name='Carta de Condução')),
                ('documentos_veiculo_url', models.URLField(blank=True, default='', help_text='RN-082: Endereço URL dos documentos comprovativos do veículo e seguro.', max_length=500, verbose_name='URL dos Documentos do Veículo')),
                ('status_onboarding', models.CharField(choices=[('PENDENTE', 'Pendente'), ('APROVADO', 'Aprovado')], db_index=True, default='PENDENTE', help_text='RN-082: Estado da verificação documental (Pendente, Aprovado).', max_length=15, verbose_name='Estado de Onboarding')),
                ('is_online', models.BooleanField(db_index=True, default=False, help_text="RN-082 / RN-083: Indica se o estafeta está online.", verbose_name='Está Online')),
                ('ultima_geolocalizacao', django.contrib.gis.db.models.fields.PointField(blank=True, geography=True, help_text='RN-083 / RN-084 / RN-094: Coordenada GPS mais recente do estafeta.', null=True, srid=4326, verbose_name='Última Geolocalização (PostGIS)')),
                ('score_reputacao', models.DecimalField(db_index=True, decimal_places=2, default=decimal.Decimal('5.00'), help_text='RN-084 / RN-085 / RN-116: Score de desempenho do estafeta.', max_digits=3, validators=[django.core.validators.MinValueValidator(decimal.Decimal('0.00')), django.core.validators.MaxValueValidator(decimal.Decimal('5.00'))], verbose_name='Score de Reputação')),
                ('saldo_carteira', models.BigIntegerField(default=0, help_text='Secção 11 / RN-146 / RN-148: Saldo financeiro em unidades mínimas inteiras.', verbose_name='Saldo da Carteira (Inteiro)')),
                ('utilizador', models.OneToOneField(help_text='RN-082: Conta de utilizador (CustomUser) associada a este estafeta.', on_delete=django.db.models.deletion.CASCADE, related_name='perfil_estafeta', to=settings.AUTH_USER_MODEL, verbose_name='Utilizador')),
            ],
            options={
                'verbose_name': 'Estafeta',
                'verbose_name_plural': 'Estafetas',
                'db_table': 'logistics_estafeta',
            },
        ),
        migrations.CreateModel(
            name='Entrega',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) da entrega.', primary_key=True, serialize=False, verbose_name='ID da Entrega')),
                ('estado_logistico', models.CharField(choices=[('PENDENTE', 'Pendente'), ('ATRIBUIDO', 'Atribuído'), ('RECOLHIDO', 'Recolhido'), ('EM_TRANSITO', 'Em Trânsito'), ('ENTREGUE', 'Entregue'), ('FALHOU', 'Falhou')], db_index=True, default='PENDENTE', help_text='Secção 11: Estado da corrida.', max_length=20, verbose_name='Estado Logístico da Entrega')),
                ('estado_entrega', models.CharField(choices=[('PENDENTE', 'Pendente'), ('ATRIBUIDO', 'Atribuído'), ('RECOLHIDO', 'Recolhido'), ('EM_TRANSITO', 'Em Trânsito'), ('ENTREGUE', 'Entregue'), ('FALHOU', 'Falhou')], default='PENDENTE', max_length=20, verbose_name='Estado da Entrega (Legado)')),
                ('distancia_metros', models.PositiveIntegerField(default=0, help_text='Secção 11 / RN-090: Distância da rota de entrega expressa em metros.', verbose_name='Distância (Metros)')),
                ('eta_estimada', models.DateTimeField(blank=True, db_index=True, help_text='RN-029 / Secção 11: Timestamp estimado de chegada ao endereço do cliente.', null=True, verbose_name='ETA Estimada')),
                ('eta_timestamp', models.DateTimeField(blank=True, null=True, verbose_name='ETA Timestamp (Legado)')),
                ('pin_entrega', models.CharField(default=apps.logistics.models.gerar_pin_4_digitos, help_text='RN-095: Código numérico de 4 dígitos exigido para validar a entrega.', max_length=4, validators=[django.core.validators.RegexValidator(message='RN-095: O PIN de entrega tem de conter exatamente 4 dígitos numéricos.', regex='^\\d{4}$')], verbose_name='PIN de Entrega (4 Dígitos)')),
                ('prova_foto_url', models.URLField(blank=True, default='', help_text='RN-048 / RN-095: Fotografia comprovativa da entrega.', max_length=500, null=True, verbose_name='URL da Foto de Prova de Entrega')),
                ('prova_geolocalizacao', django.contrib.gis.db.models.fields.PointField(blank=True, geography=True, help_text='RN-048 / RN-095: Ponto geográfico capturado na conclusão da entrega.', null=True, srid=4326, verbose_name='Prova de Geolocalização (PostGIS)')),
                ('prova_gps', django.contrib.gis.db.models.fields.PointField(blank=True, geography=True, null=True, srid=4326, verbose_name='Prova GPS (Legado)')),
                ('estafeta', models.ForeignKey(blank=True, help_text='Secção 11 / RN-085: Estafeta atualmente atribuído.', null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='entregas', to='logistics.estafeta', verbose_name='Estafeta')),
                ('pedido', models.OneToOneField(help_text='Secção 11: Pedido correspondente a esta entrega.', on_delete=django.db.models.deletion.PROTECT, related_name='entrega_logistica', to='orders.pedido', verbose_name='Pedido')),
            ],
            options={
                'verbose_name': 'Entrega',
                'verbose_name_plural': 'Entregas',
                'db_table': 'logistics_entrega',
            },
        ),
        migrations.AddIndex(
            model_name='estafeta',
            index=models.Index(fields=['status_onboarding', 'is_online', '-score_reputacao'], name='idx_estafeta_despacho'),
        ),
        migrations.AddIndex(
            model_name='entrega',
            index=models.Index(fields=['estado_entrega', 'eta_timestamp'], name='idx_entrega_estado_eta'),
        ),
        migrations.AddIndex(
            model_name='entrega',
            index=models.Index(fields=['estafeta', 'estado_entrega'], name='idx_entrega_estafeta_estado'),
        ),
    ]

