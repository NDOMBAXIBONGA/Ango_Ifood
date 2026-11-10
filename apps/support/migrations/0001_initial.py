# Generated manually for support initial migration
import uuid
from django.conf import settings
import django.core.validators
from django.db import migrations, models
import django.db.models.deletion
import django.utils.timezone


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('orders', '0001_initial'),
    ]

    operations = [
        migrations.CreateModel(
            name='Parametro',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) do parâmetro.', primary_key=True, serialize=False, verbose_name='ID do Parâmetro')),
                ('chave', models.CharField(db_index=True, help_text="Identificador canónico único do parâmetro.", max_length=100, unique=True, verbose_name='Chave do Parâmetro')),
                ('nome', models.CharField(help_text="Designação amigável descrita na tabela da Secção 8.", max_length=150, verbose_name='Nome do Parâmetro')),
                ('valor', models.CharField(help_text="Valor predefinido e formatado.", max_length=100, verbose_name='Valor Configurado')),
                ('valor_numerico', models.DecimalField(blank=True, decimal_places=2, help_text='Representação numérica padrão para operações lógicas diretas.', max_digits=14, null=True, verbose_name='Valor Numérico Base')),
                ('unidade', models.CharField(blank=True, default='', help_text="Unidade da grandeza (ex.: 'segundos', 'km', 'Kz').", max_length=30, verbose_name='Unidade de Medida')),
                ('ambito', models.CharField(choices=[('Global', 'Global'), ('Pais', 'País'), ('Cidade', 'Cidade'), ('Zona', 'Zona Logística'), ('Parceiro', 'Parceiro'), ('Loja', 'Loja'), ('Contrato', 'Contrato'), ('Perfil', 'Perfil / Agente')], db_index=True, default='Global', help_text='Secção 8 / Secção 11: Escopo do parâmetro.', max_length=30, verbose_name='Âmbito de Aplicação')),
                ('regra_associada', models.CharField(blank=True, db_index=True, default='', help_text="Referência à regra da especificação funcional.", max_length=30, verbose_name='Regra de Negócio Associada')),
                ('descricao', models.TextField(blank=True, default='', help_text='Explicação do impacto operacional e de negócio deste parâmetro.', verbose_name='Descrição e Notas Operacionais')),
                ('vigencia_inicio', models.DateTimeField(db_index=True, default=django.utils.timezone.now, help_text='Secção 8 / Secção 11: Data e hora a partir da qual entra em vigor.', verbose_name='Início de Vigência')),
                ('vigencia_fim', models.DateTimeField(blank=True, help_text='Secção 8 / Secção 11: Data limite de validade.', null=True, verbose_name='Fim de Vigência')),
                ('versao', models.PositiveIntegerField(default=1, help_text='Secção 8 / Secção 11: Número incremental de versionamento.', verbose_name='Versão do Parâmetro')),
                ('autor', models.CharField(default='DevOps / Sistema', help_text='Secção 8 / Secção 11: Responsável pela definição.', max_length=150, verbose_name='Autor da Configuração')),
                ('data_criacao', models.DateTimeField(auto_now_add=True, verbose_name='Data de Criação')),
                ('data_atualizacao', models.DateTimeField(auto_now=True, verbose_name='Data de Atualização')),
            ],
            options={
                'verbose_name': 'Parâmetro de Sistema',
                'verbose_name_plural': 'Parâmetros de Sistema',
                'db_table': 'support_parametro',
                'ordering': ['ambito', 'chave'],
            },
        ),
        migrations.CreateModel(
            name='TicketDisputa',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) do ticket de disputa.', primary_key=True, serialize=False, verbose_name='ID do Ticket / Disputa')),
                ('tipo_incidente', models.CharField(choices=[('DISPUTA_COMERCIAL', 'Disputa Comercial / Contratual'), ('ITEM_FALTOU', 'Item em Falta / Incorreto'), ('DERRAME_DANOS', 'Derrame ou Danos na Embalagem'), ('ATRASO_GRAVE', 'Atraso Excessivo na Entrega'), ('REACAO_ALERGICA', 'Reação Alérgica Grave (RN-140)'), ('INTOXICACAO_ALIMENTAR', 'Intoxicação Alimentar (RN-140)'), ('OUTRO', 'Outro Incidente Operacional')], db_index=True, default='DISPUTA_COMERCIAL', help_text='RN-138 / RN-140: Classificação do incidente ou reclamação.', max_length=30, verbose_name='Tipo de Incidente')),
                ('prioridade', models.CharField(choices=[('BAIXA', 'Baixa'), ('MEDIA', 'Média'), ('ALTA', 'Alta (SLA < 5 min - RN-139)'), ('CRITICA', 'Crítica (Segurança e Saúde Pública - RN-140)')], db_index=True, default='MEDIA', help_text='RN-139: Nível de prioridade com impacto no SLA de escalamento imediato.', max_length=15, verbose_name='Prioridade')),
                ('motivo', models.TextField(help_text='RN-141: Descrição detalhada do motivo que originou o ticket.', verbose_name='Motivo da Disputa')),
                ('estado', models.CharField(choices=[('ABERTO', 'Aberto'), ('EM_ANALISE', 'Em Análise'), ('RESOLVIDO', 'Resolvido')], db_index=True, default='ABERTO', help_text='Secção 11 / RN-141: Estado atual do ticket.', max_length=20, verbose_name='Estado da Disputa')),
                ('decisao', models.CharField(blank=True, choices=[('Procedente_Cliente', 'Procedente_Cliente (A favor do Cliente)'), ('Procedente_Parceiro', 'Procedente_Parceiro (A favor do Parceiro)'), ('Improcedente', 'Improcedente (Rejeitada)')], db_index=True, default='', help_text='RN-141: Decisão da mediação.', max_length=30, verbose_name='Decisão')),
                ('motivo_justificacao', models.TextField(blank=True, default='', help_text='RN-141 / RN-142: Justificação fundamentada da decisão.', verbose_name='Justificação Fundamentada')),
                ('compensacao_valor', models.PositiveBigIntegerField(default=0, help_text='RN-059 / RN-106 / RN-141: Montante de compensação ou reembolso em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Valor de Compensação (Inteiro)')),
                ('is_alerta_escalado', models.BooleanField(default=False, help_text='RN-139: Indica se a tarefa Celery de escalamento de SLA já foi emitida.', verbose_name='Alerta Escalado')),
                ('data_criacao', models.DateTimeField(auto_now_add=True, db_index=True, verbose_name='Data de Criação')),
                ('data_atualizacao', models.DateTimeField(auto_now=True, verbose_name='Data de Atualização')),
                ('data_resolucao', models.DateTimeField(blank=True, db_index=True, null=True, verbose_name='Data de Resolução')),
                ('autor_decisao', models.ForeignKey(blank=True, help_text='RN-141 / RN-142: Operador/Agente de Suporte responsável pelo registo da decisão.', null=True, on_delete=django.db.models.deletion.PROTECT, related_name='disputas_decididas', to=settings.AUTH_USER_MODEL, verbose_name='Autor da Decisão')),
                ('pedido', models.ForeignKey(help_text='Secção 11 / RN-141: Pedido ao qual esta disputa diz respeito.', on_delete=django.db.models.deletion.PROTECT, related_name='tickets_disputa', to='orders.pedido', verbose_name='Pedido')),
                ('supervisor_aprovador', models.ForeignKey(blank=True, help_text='RN-106: Supervisor que autorizou a compensação superior a 3.000 Kz.', null=True, on_delete=django.db.models.deletion.PROTECT, related_name='compensacoes_aprovadas', to=settings.AUTH_USER_MODEL, verbose_name='Supervisor Aprovador')),
            ],
            options={
                'verbose_name': 'Ticket / Disputa',
                'verbose_name_plural': 'Tickets / Disputas',
                'db_table': 'support_ticket_disputa',
                'ordering': ['-data_criacao'],
            },
        ),
        migrations.AddIndex(
            model_name='ticketdisputa',
            index=models.Index(fields=['pedido', 'estado'], name='idx_disputa_ped_est'),
        ),
        migrations.AddIndex(
            model_name='ticketdisputa',
            index=models.Index(fields=['tipo_incidente', 'prioridade'], name='idx_disputa_tp_prio'),
        ),
    ]
