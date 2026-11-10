# Generated manually for promotions initial migration
import uuid
import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):

    initial = True

    dependencies = [
    ]

    operations = [
        migrations.CreateModel(
            name='CupaoDesconto',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, help_text='Secção 11: Identificador único universal (UUID v4) do cupão de desconto.', primary_key=True, serialize=False, verbose_name='ID do Cupão')),
                ('codigo', models.CharField(db_index=True, help_text="RN-056: Código promocional único (ex.: 'BEMVINDO1000').", max_length=50, unique=True, verbose_name='Código do Cupão')),
                ('tipo_desconto', models.CharField(choices=[('FIXO', 'Valor Fixo'), ('PERCENTAGEM', 'Percentagem')], help_text='RN-056: Define se o desconto é de valor Fixo ou Percentagem.', max_length=15, verbose_name='Tipo de Desconto')),
                ('valor', models.PositiveBigIntegerField(help_text='RN-056 / RN-059: Valor inteiro do desconto.', validators=[django.core.validators.MinValueValidator(1)], verbose_name='Valor do Desconto (Inteiro)')),
                ('validade_inicio', models.DateTimeField(db_index=True, help_text='RN-056: Data e hora a partir da qual o cupão pode ser utilizado.', verbose_name='Início de Validade')),
                ('validade_fim', models.DateTimeField(db_index=True, help_text='RN-056: Data e hora em que o cupão expira.', verbose_name='Fim de Validade')),
                ('montante_minimo_pedido', models.PositiveBigIntegerField(default=0, help_text='RN-056 / RN-059: Subtotal mínimo do pedido em unidades mínimas inteiras.', validators=[django.core.validators.MinValueValidator(0)], verbose_name='Montante Mínimo do Pedido (Inteiro)')),
                ('limite_global_uso', models.PositiveIntegerField(default=1000, help_text='RN-056: Número máximo total de vezes que este cupão pode ser resgatado.', validators=[django.core.validators.MinValueValidator(1)], verbose_name='Limite Global de Uso')),
                ('limite_por_utilizador', models.PositiveSmallIntegerField(default=1, help_text='RN-056: Número máximo de vezes que um mesmo cliente pode utilizar este cupão.', validators=[django.core.validators.MinValueValidator(1)], verbose_name='Limite de Uso por Utilizador')),
                ('financiador', models.CharField(choices=[('PLATAFORMA', 'Plataforma'), ('PARCEIRO', 'Parceiro'), ('PARTILHADO', 'Partilhado')], default='PLATAFORMA', help_text='RN-055 / RN-056: Entidade que financia o desconto.', max_length=15, verbose_name='Financiador do Desconto')),
            ],
            options={
                'verbose_name': 'Cupão de Desconto',
                'verbose_name_plural': 'Cupões de Desconto',
                'db_table': 'promotions_cupao_desconto',
                'ordering': ['-validade_fim', 'codigo'],
            },
        ),
        migrations.AddIndex(
            model_name='cupaodesconto',
            index=models.Index(fields=['codigo', 'validade_inicio', 'validade_fim'], name='idx_cupao_codigo_validade'),
        ),
    ]

