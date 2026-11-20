from django.db import migrations


def seed_default_parametros(apps, schema_editor):
    Parametro = apps.get_model("support", "Parametro")

    defaults = [
        # 1. BRANDING & IDENTIDADE VISUAL
        {
            "chave": "APP_NAME",
            "nome": "Nome Oficial da Aplicação",
            "categoria": "BRANDING",
            "tipo_dado": "STRING",
            "valor": "Ango_Ifood Delivery",
            "descricao": "Nome exibido na barra superior, ecrãs iniciais e comunicações.",
        },
        {
            "chave": "APP_SLOGAN",
            "nome": "Slogan da Plataforma",
            "categoria": "BRANDING",
            "tipo_dado": "STRING",
            "valor": "A maior plataforma de entregas e gastronomia de Angola",
            "descricao": "Frase de efeito exibida nas páginas de abertura e splash.",
        },
        {
            "chave": "APP_LOGO_URL",
            "nome": "Logótipo Principal da Aplicação",
            "categoria": "BRANDING",
            "tipo_dado": "IMAGE_URL",
            "valor": "/static/img/logo.png",
            "descricao": "URL do logótipo em alta resolução para cabeçalhos e vitrines.",
        },
        {
            "chave": "APP_ICON_URL",
            "nome": "Ícone Oficial da App",
            "categoria": "BRANDING",
            "tipo_dado": "IMAGE_URL",
            "valor": "/static/img/app_icon.png",
            "descricao": "Ícone para notificações push, web app manifest e splash.",
        },

        # 2. DESIGN SYSTEM & ESTILIZAÇÃO
        {
            "chave": "PRIMARY_COLOR",
            "nome": "Cor Primária Institucional",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "COLOR_HEX",
            "valor": "#EA1D2C",
            "descricao": "Cor dos botões principais, cabeçalhos de destaque e links.",
        },
        {
            "chave": "SECONDARY_COLOR",
            "nome": "Cor Secundária / Contrastes",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "COLOR_HEX",
            "valor": "#0F172A",
            "descricao": "Cor para textos principais e elementos escuros de navegação.",
        },
        {
            "chave": "ACCENT_COLOR",
            "nome": "Cor de Realce (Accent)",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "COLOR_HEX",
            "valor": "#F59E0B",
            "descricao": "Cor de estrelas de avaliação, badges promocionais e alertas.",
        },
        {
            "chave": "BACKGROUND_SCREEN_COLOR",
            "nome": "Cor de Fundo dos Ecrãs",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "COLOR_HEX",
            "valor": "#F8FAFC",
            "descricao": "Cor de fundo das páginas principais na app e na web.",
        },
        {
            "chave": "CARD_BACKGROUND_COLOR",
            "nome": "Cor de Fundo dos Cards",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "COLOR_HEX",
            "valor": "#FFFFFF",
            "descricao": "Superfície dos cartões de restaurantes, itens e modais.",
        },
        {
            "chave": "BORDER_RADIUS_BASE",
            "nome": "Raio de Borda dos Botões e Cards",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "STRING",
            "valor": "14px",
            "descricao": "Arredondamento visual padrão dos componentes na interface.",
        },
        {
            "chave": "FONT_FAMILY",
            "nome": "Família Tipográfica Principal",
            "categoria": "DESIGN_SYSTEM",
            "tipo_dado": "STRING",
            "valor": "Inter, system-ui, -apple-system, sans-serif",
            "descricao": "Fonte aplicada em todos os textos da aplicação.",
        },

        # 3. TEXTOS, AVISOS & MICROCOPY (CMS)
        {
            "chave": "HOME_SEARCH_PLACEHOLDER",
            "nome": "Texto da Barra de Pesquisa",
            "categoria": "TEXTOS_CMS",
            "tipo_dado": "STRING",
            "valor": "O que vai pedir hoje? Restaurantes, pratos ou bebidas...",
            "descricao": "Texto cinzento (placeholder) exibido no campo de pesquisa da Home.",
        },
        {
            "chave": "CART_EMPTY_MESSAGE",
            "nome": "Mensagem de Carrinho Vazio",
            "categoria": "TEXTOS_CMS",
            "tipo_dado": "STRING",
            "valor": "O seu cesto está vazio. Explore os melhores restaurantes e adicione pratos deliciosos!",
            "descricao": "Mensagem motivacional exibida no carrinho quando sem artigos.",
        },
        {
            "chave": "CHECKOUT_TERMS_DISCLAIMER",
            "nome": "Aviso Legal no Checkout",
            "categoria": "TEXTOS_CMS",
            "tipo_dado": "STRING",
            "valor": "Ao confirmar o pedido, concorda com as condições de serviço e frete do Ango_Ifood.",
            "descricao": "Nota de rodapé exibida imediatamente antes do botão de submissão do pedido.",
        },
        {
            "chave": "AUTH_OTP_HEADER_TEXT",
            "nome": "Título do Ecrã de Login OTP",
            "categoria": "TEXTOS_CMS",
            "tipo_dado": "STRING",
            "valor": "Qual é o seu e-mail?",
            "descricao": "Título principal exibido na tela de autenticação rápida.",
        },
        {
            "chave": "AUTH_OTP_SUBTITLE_TEXT",
            "nome": "Subtítulo do Ecrã de Login OTP",
            "categoria": "TEXTOS_CMS",
            "tipo_dado": "STRING",
            "valor": "Enviaremos um código de 6 dígitos para validar a sua identidade de forma rápida e segura.",
            "descricao": "Explicação exibida logo abaixo do título na autenticação.",
        },

        # 4. TAXAS, TARIFAS & LIMITES FINANCEIROS
        {
            "chave": "TAXA_BASE_ENTREGA_AOA",
            "nome": "Taxa Base de Frete (AOA)",
            "categoria": "FINANCAS_TAXAS",
            "tipo_dado": "NUMBER",
            "valor": "500",
            "valor_numerico": 500.00,
            "unidade": "Kz",
            "descricao": "Tarifa mínima inicial fixa cobrada em cada entrega.",
        },
        {
            "chave": "VALOR_KM_ENTREGA_AOA",
            "nome": "Custo por Quilómetro de Frete (AOA/km)",
            "categoria": "FINANCAS_TAXAS",
            "tipo_dado": "NUMBER",
            "valor": "150",
            "valor_numerico": 150.00,
            "unidade": "Kz/km",
            "descricao": "Valor incremental por cada km calculado pelo motor OSRM.",
        },
        {
            "chave": "COMISSAO_MARKETPLACE_PERCENTAGEM",
            "nome": "Comissão Base do Marketplace (%)",
            "categoria": "FINANCAS_TAXAS",
            "tipo_dado": "NUMBER",
            "valor": "10",
            "valor_numerico": 10.00,
            "unidade": "%",
            "descricao": "Percentagem retida das vendas de restaurantes parceiros.",
        },
        {
            "chave": "VALOR_MINIMO_PEDIDO_AOA",
            "nome": "Valor Mínimo de Pedido (AOA)",
            "categoria": "FINANCAS_TAXAS",
            "tipo_dado": "NUMBER",
            "valor": "1000",
            "valor_numerico": 1000.00,
            "unidade": "Kz",
            "descricao": "Total mínimo de produtos no carrinho para permitir checkout.",
        },
        {
            "chave": "VALOR_MINIMO_SAQUE_AOA",
            "nome": "Valor Mínimo de Saque de Parceiros (AOA)",
            "categoria": "FINANCAS_TAXAS",
            "tipo_dado": "NUMBER",
            "valor": "2000",
            "valor_numerico": 2000.00,
            "unidade": "Kz",
            "descricao": "Saldo mínimo em carteira para solicitar repasse bancário.",
        },

        # 5. LOGÍSTICA & OPERAÇÕES
        {
            "chave": "RAIO_MAXIMO_ENTREGA_KM",
            "nome": "Raio Máximo de Entrega (km)",
            "categoria": "LOGISTICA",
            "tipo_dado": "NUMBER",
            "valor": "25",
            "valor_numerico": 25.00,
            "unidade": "km",
            "descricao": "Distância linear máxima entre restaurante e morada do cliente.",
        },
        {
            "chave": "FATOR_CORRECAO_URBANA",
            "nome": "Fator de Correção Urbana (Trânsito)",
            "categoria": "LOGISTICA",
            "tipo_dado": "NUMBER",
            "valor": "1.25",
            "valor_numerico": 1.25,
            "descricao": "Multiplicador sobre a rota para compensar topografia e vias.",
        },
        {
            "chave": "EXIGIR_PIN_ENTREGA",
            "nome": "Exigir PIN de 4 Dígitos na Entrega",
            "categoria": "LOGISTICA",
            "tipo_dado": "BOOLEAN",
            "valor": "true",
            "valor_booleano": True,
            "descricao": "Se ativo, o estafeta precisa do código do cliente para finalizar.",
        },

        # 6. FEATURE FLAGS OPERACIONAIS
        {
            "chave": "MODULO_GORJETAS_ATIVO",
            "nome": "Habilitar Gorjetas para Estafetas",
            "categoria": "FEATURE_FLAGS",
            "tipo_dado": "BOOLEAN",
            "valor": "true",
            "valor_booleano": True,
            "descricao": "Ativa a caixa de seleção de gorjetas voluntárias no checkout.",
        },
        {
            "chave": "PAGAMENTO_DINHEIRO_ATIVO",
            "nome": "Permitir Pagamento em Numerário (Cash)",
            "categoria": "FEATURE_FLAGS",
            "tipo_dado": "BOOLEAN",
            "valor": "true",
            "valor_booleano": True,
            "descricao": "Permite aos clientes pagarem em dinheiro no ato da entrega.",
        },
        {
            "chave": "PAGAMENTO_EXPRESS_ATIVO",
            "nome": "Permitir Multicaixa Express (MCX)",
            "categoria": "FEATURE_FLAGS",
            "tipo_dado": "BOOLEAN",
            "valor": "true",
            "valor_booleano": True,
            "descricao": "Habilita gateway de pagamento eletrónico EMIS / Express.",
        },
        {
            "chave": "TRACKING_GPS_AO_VIVO",
            "nome": "Tracking GPS em Tempo Real do Estafeta",
            "categoria": "FEATURE_FLAGS",
            "tipo_dado": "BOOLEAN",
            "valor": "true",
            "valor_booleano": True,
            "descricao": "Exibe o mapa interativo com o movimento do estafeta no pedido.",
        },
        {
            "chave": "MODO_MANUTENCAO",
            "nome": "Modo de Manutenção da Plataforma",
            "categoria": "FEATURE_FLAGS",
            "tipo_dado": "BOOLEAN",
            "valor": "false",
            "valor_booleano": False,
            "descricao": "Se ligado, bloqueia a app com o ecrã de manutenção do sistema.",
        },
        {
            "chave": "MENSAGEM_MANUTENCAO",
            "nome": "Mensagem Exibida no Ecrã de Manutenção",
            "categoria": "TEXTOS_CMS",
            "tipo_dado": "STRING",
            "valor": "Estamos a realizar melhorias na nossa plataforma para lhe servir melhor. Voltamos muito em breve!",
            "descricao": "Texto descritivo exibido na tela de bloqueio por manutenção.",
        },
    ]

    for item in defaults:
        chave = item["chave"]
        if not Parametro.objects.filter(chave=chave).exists():
            Parametro.objects.create(**item)


def rollback_default_parametros(apps, schema_editor):
    pass


class Migration(migrations.Migration):
    dependencies = [
        ("support", "0004_appbannerdinamico_parametrohistorico_and_more"),
    ]

    operations = [
        migrations.RunPython(seed_default_parametros, reverse_code=rollback_default_parametros),
    ]
