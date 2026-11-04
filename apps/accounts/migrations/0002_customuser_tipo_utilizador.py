from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='customuser',
            name='tipo_utilizador',
            field=models.CharField(
                choices=[
                    ('CLIENTE', 'Cliente'),
                    ('PARCEIRO', 'Parceiro / Restaurante'),
                    ('ESTAFETA', 'Estafeta / Entregador'),
                    ('ADMIN', 'Administrador'),
                ],
                db_index=True,
                default='CLIENTE',
                help_text='Perfil funcional e permissões operacionais do utilizador na plataforma.',
                max_length=20,
                verbose_name='Tipo de Utilizador / Papel',
            ),
        ),
        migrations.AddIndex(
            model_name='customuser',
            index=models.Index(fields=['tipo_utilizador'], name='idx_user_tipo_utilizador'),
        ),
    ]

