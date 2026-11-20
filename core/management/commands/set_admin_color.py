"""
Comando de Gestão do Django para Manipular as Cores Visuais do Django Admin.

Uso:
    python manage.py set_admin_color list
    python manage.py set_admin_color red
    python manage.py set_admin_color emerald
    python manage.py set_admin_color blue
    python manage.py set_admin_color purple
    python manage.py set_admin_color amber
    python manage.py set_admin_color slate
    python manage.py set_admin_color "#FF5722"
"""
from django.core.management.base import BaseCommand
from core.admin_theme import THEME_PRESETS, list_available_themes, set_admin_theme


class Command(BaseCommand):
    help = "Manipula e configura a cor primária do Django Admin (Unfold/Tailwind) em tempo real."

    def add_arguments(self, parser):
        parser.add_argument(
            "cor_ou_tema",
            type=str,
            help="Nome do tema pré-definido (red, emerald, blue, purple, amber, slate), código HEX (#RRGGBB) ou 'list'.",
        )

    def handle(self, *args, **options):
        escolha = options["cor_ou_tema"].strip()

        if escolha.lower() == "list":
            self.stdout.write(self.style.SUCCESS("🎨 Temas visuais disponíveis para o Django Admin:"))
            for t in list_available_themes():
                self.stdout.write(f"  • {t['id']:<10} -> {t['name']:<30} (HEX: {t['hex']})")
            self.stdout.write("\nVocê também pode passar qualquer código hexadecimal, ex: '#FF5722'")
            return

        try:
            set_admin_theme(escolha)
            self.stdout.write(
                self.style.SUCCESS(f"✅ Cor visual do Django Admin atualizada com sucesso para: '{escolha}'!")
            )
            self.stdout.write(self.style.NOTICE("Recarregue o painel administrativo para visualizar a alteração."))
        except Exception as exc:
            self.stdout.write(self.style.ERROR(f"❌ Erro ao atualizar cor do admin: {exc}"))
