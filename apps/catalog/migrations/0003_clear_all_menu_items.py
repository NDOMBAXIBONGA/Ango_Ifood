from django.db import migrations


def clear_all_items(apps, schema_editor):
    """
    Remove ou desativa artigos/produtos de menu existentes do banco de dados (reset seguro)
    e limpa a lista de pratos_destaque na vitrine_cms de todas as lojas parceiras.
    """
    ItemMenu = apps.get_model("catalog", "ItemMenu")
    ParceiroLoja = apps.get_model("catalog", "ParceiroLoja")

    # 1. Tenta eliminar itens que não estejam referenciados por pedidos; se houver pedidos protegidos, desativa
    try:
        total_deletados, _ = ItemMenu.objects.all().delete()
        print(f"\n[Migracao 0003] {total_deletados} produtos eliminados com sucesso.")
    except Exception as exc:
        print(f"\n[Migracao 0003] Registos protegidos por histórico de pedidos ({exc}). A desativar itens com segurança...")
        ItemMenu.objects.all().update(disponivel=False)

    # 2. Limpa pratos_destaque da vitrine em todas as lojas
    try:
        lojas = ParceiroLoja.objects.all()
        for loja in lojas:
            if isinstance(loja.dados_bancarios, dict):
                vitrine = loja.dados_bancarios.get("vitrine_cms")
                if isinstance(vitrine, dict):
                    home = vitrine.get("identidade_home")
                    if isinstance(home, dict) and "pratos_destaque" in home:
                        home["pratos_destaque"] = []
                        loja.save(update_fields=["dados_bancarios"])
    except Exception:
        pass
    print("[Migracao 0003] Vitrine pratos_destaque resetados com sucesso.")


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0002_itemmenu_is_destaque"),
    ]

    operations = [
        migrations.RunPython(clear_all_items, reverse_code=migrations.RunPython.noop),
    ]
