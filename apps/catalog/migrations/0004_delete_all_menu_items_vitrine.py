from django.db import migrations


def delete_all_menu_and_vitrine_items(apps, schema_editor):
    """
    RN-014: Remove todos os artigos e produtos do cardápio e da vitrine do parceiro
    e limpa a lista de pratos em destaque de todas as lojas.
    """
    ItemMenu = apps.get_model("catalog", "ItemMenu")
    ParceiroLoja = apps.get_model("catalog", "ParceiroLoja")

    total_itens, _ = ItemMenu.objects.all().delete()
    print(f"\n[Migracao 0004] {total_itens} produtos eliminados de todos os cardapios.")

    for loja in ParceiroLoja.objects.all():
        if isinstance(loja.dados_bancarios, dict):
            vitrine = loja.dados_bancarios.get("vitrine_cms")
            if isinstance(vitrine, dict):
                home = vitrine.get("identidade_home")
                if isinstance(home, dict):
                    home["pratos_destaque"] = []
                loja.save(update_fields=["dados_bancarios"])
    print("[Migracao 0004] Pratos em destaque da vitrine limpos com sucesso.")


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0003_clear_all_menu_items"),
    ]

    operations = [
        migrations.RunPython(
            delete_all_menu_and_vitrine_items,
            reverse_code=migrations.RunPython.noop,
        ),
    ]
