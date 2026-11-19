"""
Comando de gestão para criação e gestão de Superutilizadores no Django Admin.
Suporta execução interativa e não-interativa (ideal para ambientes locais e Cloud/Render).

Exemplo de utilização:
  python manage.py create_admin --telemovel=+244923000000 --email=admin@delivery.ao --nome="Admin Central" --password=MinhaSenhaForte123

Ou com valores padrão / variáveis de ambiente:
  python manage.py create_admin
"""
import os
from django.core.management.base import BaseCommand
from apps.accounts.models import CustomUser


class Command(BaseCommand):
    help = "Cria ou atualiza um superutilizador para o Django Admin."

    def add_arguments(self, parser):
        parser.add_argument(
            "--telemovel",
            type=str,
            default=os.getenv("DJANGO_SUPERUSER_TELEMOVEL", "+244923000000"),
            help="Número de telemóvel no formato E.164 (ex.: +244923000000).",
        )
        parser.add_argument(
            "--email",
            type=str,
            default=os.getenv("DJANGO_SUPERUSER_EMAIL", "admin@delivery.ao"),
            help="Endereço de e-mail do superutilizador.",
        )
        parser.add_argument(
            "--nome",
            type=str,
            default=os.getenv("DJANGO_SUPERUSER_NOME", "Administrador Central"),
            help="Nome completo do superutilizador.",
        )
        parser.add_argument(
            "--password",
            type=str,
            default=os.getenv("DJANGO_SUPERUSER_PASSWORD", ""),
            help="Palavra-passe do superutilizador.",
        )

    def handle(self, *args, **options):
        telemovel = options["telemovel"].strip()
        email = options["email"].strip().lower()
        nome = options["nome"].strip()
        password = options["password"]

        if not password:
            self.stdout.write(
                self.style.WARNING(
                    "Aviso: Nenhuma palavra-passe fornecida via --password ou DJANGO_SUPERUSER_PASSWORD. A definir 'Admin@Delivery2026!' como padrão."
                )
            )
            password = "Admin@Delivery2026!"

        # Verifica se o utilizador já existe por telemóvel ou e-mail
        user = CustomUser.objects.filter(telemovel=telemovel).first()
        if not user:
            user = CustomUser.objects.filter(email=email).first()

        if user:
            self.stdout.write(
                self.style.WARNING(
                    f"Utilizador '{user.nome}' já existe ({user.telemovel} / {user.email}). A atualizar permissões de Superutilizador e senha..."
                )
            )
            user.is_staff = True
            user.is_superuser = True
            user.is_active = True
            user.estado = CustomUser.EstadoConta.ATIVO
            user.tipo_utilizador = CustomUser.TipoUtilizador.ADMIN
            user.set_password(password)
            user.save()
            self.stdout.write(
                self.style.SUCCESS(
                    f"Superutilizador atualizado com sucesso!\n"
                    f"Telemóvel: {user.telemovel}\n"
                    f"Email: {user.email}\n"
                    f"Acesso Admin: /admin/"
                )
            )
        else:
            user = CustomUser.objects.create_superuser(
                telemovel=telemovel,
                email=email,
                nome=nome,
                password=password,
                tipo_utilizador=CustomUser.TipoUtilizador.ADMIN,
                estado=CustomUser.EstadoConta.ATIVO,
            )
            self.stdout.write(
                self.style.SUCCESS(
                    f"Superutilizador criado com sucesso!\n"
                    f"Telemóvel: {user.telemovel}\n"
                    f"Email: {user.email}\n"
                    f"Acesso Admin: /admin/"
                )
            )
