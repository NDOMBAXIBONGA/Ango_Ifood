# Generated manually for orders initial migration
import uuid
from django.conf import settings
import django.core.validators
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('catalog', '0001_initial'),
        ('accounts', '0002_customuser_tipo_utilizador'),
    ]

    operations = [
        migrations.CreateModel(
            name='Pedido',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) do pedido.', primary_key=True, serialize=False, verbose_name='ID do Pedido')),
                ('estado', models.CharField(choices=[('CRIADO', '1. Criado (Carrinho Validado)'), ('PAGAMENTO', '2. Pagamento (Autorizado/Capturado)'), ('AGUARDA_PARCEIRO', '3. Aguarda Parceiro'), ('ACEITE', '4. Aceite pelo Parceiro'), ('EM_PREPARACAO', '5. Preparação em Curso'), ('PRONTO', '6. Pronto para Recolha'), ('RECOLHIDO', '7. Recolhido pelo Estafeta'), ('EM_TRANSITO', '8. Em Trânsito (A Caminho)'), ('ENTREGUE', '9. Entregue (PIN Confirmado)'), ('CONCLUIDO', '10. Concluído (Liquidação)'), ('REJEITADO', 'Excecional: Rejeitado pelo Parceiro/Timeout'), ('CANCELADO', 'Excecional: Cancelado'), ('FALHA_ENTREGA', 'Excecional: Falha de Entrega'), ('REEMBOLSADO', 'Excecional: Reembolsado (Total ou Parcial)')], db_index=True, default='CRIADO', help_text='Secção 5: Estado atual do pedido no ciclo de vida do OMS.', max_length=25, verbose_name='Estado do Pedido')),
                ('subtotal', models.PositiveBigIntegerField(default=0, help_text='RN-050 / RN-059: Soma dos produtos e opções em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Subtotal dos Produtos (Inteiro)')),
                ('taxa_entrega', models.PositiveBigIntegerField(default=0, help_text='RN-050 / RN-051 / RN-059: Valor da taxa de entrega em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Taxa de Entrega (Inteiro)')),
                ('taxa_servico', models.PositiveBigIntegerField(default=0, help_text='RN-050 / RN-053 / RN-059: Taxa de utilização da plataforma em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Taxa de Serviço (Inteiro)')),
                ('taxa_pequeno_pedido', models.PositiveBigIntegerField(default=0, help_text='RN-041 / RN-050 / RN-059: Suplemento cobrado quando o subtotal é inferior ao pedido mínimo.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Taxa de Pequeno Pedido (Inteiro)')),
                ('gorjeta_estafeta', models.PositiveBigIntegerField(default=0, help_text='RN-050 / RN-058 / RN-059: Valor opcional de gorjeta para o estafeta.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Gorjeta ao Estafeta (Inteiro)')),
                ('descontos', models.PositiveBigIntegerField(default=0, help_text='RN-050 / RN-055 / RN-056 / RN-059: Montante total deduzido por cupões.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Total de Descontos (Inteiro)')),
                ('total_cobrado', models.PositiveBigIntegerField(default=0, help_text='RN-050 / RN-059: Total cobrado ao cliente em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Total Cobrado ao Cliente (Inteiro)')),
                ('metodo_pagamento', models.CharField(choices=[('CARTAO', 'Cartão Bancário (Débito/Crédito)'), ('CARTEIRA_DIGITAL', 'Carteira Digital / Mobile Money'), ('REFERENCIA_TRANSFERENCIA', 'Referência Multibanco / Transferência'), ('CARTEIRA_INTERNA', 'Carteira Interna da Plataforma'), ('NUMERARIO', 'Numerário na Entrega')], help_text='RN-065 / Secção 11: Meio de pagamento utilizado pelo cliente no checkout.', max_length=30, verbose_name='Método de Pagamento')),
                ('cotacao_expira_em', models.DateTimeField(blank=True, db_index=True, help_text='RN-043: Data e hora limite até à qual os valores cotados são garantidos.', null=True, verbose_name='Cotação Expira Em')),
                ('data_criacao', models.DateTimeField(auto_now_add=True, db_index=True, help_text='Secção 11: Data e hora exatas em que o pedido foi criado.', verbose_name='Data de Criação')),
                ('data_atualizacao', models.DateTimeField(auto_now=True, help_text='Secção 11: Data e hora da última atualização de estado do pedido.', verbose_name='Data de Atualização')),
                ('cliente', models.ForeignKey(help_text='Secção 11 / RN-007: Utilizador cliente que realizou o pedido.', on_delete=django.db.models.deletion.PROTECT, related_name='pedidos', to=settings.AUTH_USER_MODEL, verbose_name='Cliente')),
                ('loja', models.ForeignKey(help_text='Secção 11 / RN-040: Loja parceira responsável pela preparação do pedido.', on_delete=django.db.models.deletion.PROTECT, related_name='pedidos', to='catalog.parceiroloja', verbose_name='Parceiro / Loja')),
            ],
            options={
                'verbose_name': 'Pedido',
                'verbose_name_plural': 'Pedidos',
                'db_table': 'orders_pedido',
                'ordering': ['-data_criacao'],
            },
        ),
        migrations.CreateModel(
            name='LinhaPedido',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) da linha do pedido.', primary_key=True, serialize=False, verbose_name='ID da Linha de Pedido')),
                ('quantidade', models.PositiveSmallIntegerField(default=1, help_text='RN-042: Quantidade de unidades deste item.', validators=[django.core.validators.MinValueValidator(1), django.core.validators.MaxValueValidator(20)], verbose_name='Quantidade')),
                ('preco_unitario_historico', models.PositiveBigIntegerField(default=0, help_text='RN-016 / RN-020 / RN-043 / RN-059: Preço unitário congelado na cotação.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Preço Unitário Histórico (Inteiro)')),
                ('preco_unitario_no_momento', models.PositiveBigIntegerField(default=0, help_text='Campo de compatibilidade com o checkout OMS.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Preço Unitário no Momento (Inteiro)')),
                ('notas', models.TextField(blank=True, default='', help_text='RN-045: Notas de preparação deixadas pelo cliente ao parceiro.', null=True, verbose_name='Notas ao Item')),
                ('item', models.ForeignKey(help_text='Secção 11: Produto do catálogo selecionado pelo cliente.', on_delete=django.db.models.deletion.PROTECT, related_name='linhas_pedido', to='catalog.itemmenu', verbose_name='Item do Menu')),
                ('pedido', models.ForeignKey(help_text='Secção 11: Pedido em que esta linha de artigo está incluída.', on_delete=django.db.models.deletion.CASCADE, related_name='linhas', to='orders.pedido', verbose_name='Pedido')),
            ],
            options={
                'verbose_name': 'Linha de Pedido',
                'verbose_name_plural': 'Linhas de Pedido',
                'db_table': 'orders_linha_pedido',
            },
        ),
        migrations.CreateModel(
            name='LinhaPedidoOpcaoSelecionada',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) da opção selecionada na linha.', primary_key=True, serialize=False, verbose_name='ID da Opção da Linha')),
                ('preco_adicional_historico', models.PositiveBigIntegerField(default=0, help_text='RN-020 / RN-059: Preço adicional da opção congelado no momento do checkout.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Preço Adicional Histórico (Inteiro)')),
                ('preco_no_momento', models.PositiveBigIntegerField(default=0, help_text='Campo de compatibilidade com o checkout OMS.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Preço da Opção no Momento (Inteiro)')),
                ('linha_pedido', models.ForeignKey(help_text='Secção 11: Linha de pedido que contém esta opção personalizada.', on_delete=django.db.models.deletion.CASCADE, related_name='opcoes_selecionadas', to='orders.linhapedido', verbose_name='Linha de Pedido')),
                ('opcao', models.ForeignKey(help_text='RN-014 / Secção 11: Opção ou complemento escolhido pelo cliente.', on_delete=django.db.models.deletion.PROTECT, related_name='selecoes_pedido', to='catalog.opcaoitem', verbose_name='Opção de Item')),
            ],
            options={
                'verbose_name': 'Opção da Linha de Pedido',
                'verbose_name_plural': 'Opções das Linhas de Pedido',
                'db_table': 'orders_linha_pedido_opcao',
            },
        ),
        migrations.AddIndex(
            model_name='pedido',
            index=models.Index(fields=['cliente', '-data_criacao'], name='idx_pedido_cliente_data'),
        ),
        migrations.AddIndex(
            model_name='pedido',
            index=models.Index(fields=['loja', 'estado', '-data_criacao'], name='idx_pedido_loja_estado'),
        ),
        migrations.AddIndex(
            model_name='pedido',
            index=models.Index(fields=['estado', '-data_criacao'], name='idx_pedido_estado_data'),
        ),
        migrations.AddIndex(
            model_name='linhapedido',
            index=models.Index(fields=['pedido'], name='idx_linhapedido_pedido'),
        ),
    ]
