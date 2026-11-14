from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('catalog', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='itemmenu',
            name='is_destaque',
            field=models.BooleanField(
                db_index=True,
                default=False,
                help_text="Se True, o artigo surge destacado na secção de 'Pratos Principais em Destaque' da Página Inicial da loja.",
                verbose_name='Destaque na Página Inicial',
            ),
        ),
        migrations.AddIndex(
            model_name='itemmenu',
            index=models.Index(fields=['loja', 'is_destaque'], name='idx_item_loja_dest'),
        ),
    ]
