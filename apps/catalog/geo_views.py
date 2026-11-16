"""
API de Cobertura Geográfica e Expansão Nacional de Angola (18 Províncias e Municípios).
Permite a clientes, estafetas e parceiros de qualquer região de Angola descobrir lojas,
registar moradas precisas e validar entregas em todos os hubs urbanos do país.
"""
from __future__ import annotations

import math
from typing import Any

from rest_framework import permissions, status
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.catalog.models import ParceiroLoja


# Dados canónicos das 18 Províncias de Angola
PROVINCIAS_ANGOLA: list[dict[str, Any]] = [
    {
        "codigo": "LUA",
        "nome": "Luanda",
        "capital": "Luanda",
        "regiao": "Centro-Norte",
        "latitude": -8.8368,
        "longitude": 13.2343,
        "municipios_principais": [
            "Luanda", "Talatona", "Belas", "Cazenga", "Viana",
            "Kilamba Kiaxi", "Cacuaco", "Quiçama", "Icolo e Bengo"
        ],
        "zonas_rapidas": [
            {"nome": "Ingombota / Centro", "lat": -8.8147, "lng": 13.2343, "ref": "Marginal de Luanda"},
            {"nome": "Talatona", "lat": -8.9167, "lng": 13.1833, "ref": "Belas Business Park"},
            {"nome": "Centralidade do Kilamba", "lat": -8.9950, "lng": 13.2680, "ref": "Quarteirão Q"},
            {"nome": "Maianga / Alvalade", "lat": -8.8399, "lng": 13.2345, "ref": "Hotel Alvalade"},
            {"nome": "Morro Bento", "lat": -8.8850, "lng": 13.1950, "ref": "Avenida 21 de Janeiro"},
            {"nome": "Viana / Zango", "lat": -8.9030, "lng": 13.3740, "ref": "Vila de Viana"},
        ],
    },
    {
        "codigo": "BGU",
        "nome": "Benguela",
        "capital": "Benguela",
        "regiao": "Centro-Oeste",
        "latitude": -12.5763,
        "longitude": 13.4055,
        "municipios_principais": [
            "Benguela", "Lobito", "Catumbela", "Baía Farta", "Ganda",
            "Cubal", "Caimbambo", "Bocoio", "Balombo", "Chongorói"
        ],
        "zonas_rapidas": [
            {"nome": "Benguela Centro", "lat": -12.5763, "lng": 13.4055, "ref": "Largo da Peça / Praia Morena"},
            {"nome": "Lobito / Restinga", "lat": -12.3644, "lng": 13.5360, "ref": "Avenida da Independência / Porto"},
            {"nome": "Catumbela", "lat": -12.4310, "lng": 13.5470, "ref": "Margem do Rio Catumbela"},
            {"nome": "Baía Farta", "lat": -12.6080, "lng": 13.1930, "ref": "Zona Fabril e Pesqueira"},
        ],
    },
    {
        "codigo": "HUA",
        "nome": "Huambo",
        "capital": "Huambo",
        "regiao": "Planalto Central",
        "latitude": -12.7761,
        "longitude": 15.7392,
        "municipios_principais": [
            "Huambo", "Caála", "Bailundo", "Ekunha", "Longonjo",
            "Ukuma", "Chinjenje", "Chicala Cholohanga", "Catchiungo", "Mungo", "Londuimbali"
        ],
        "zonas_rapidas": [
            {"nome": "Huambo Centro (Cidade Alta)", "lat": -12.7761, "lng": 15.7392, "ref": "Jardim da Cultura / Av. Norton de Matos"},
            {"nome": "Caála", "lat": -12.8525, "lng": 15.5606, "ref": "Centro Urbano de Caála"},
            {"nome": "Bailundo", "lat": -12.1950, "lng": 15.8680, "ref": "Sede Histórica do Bailundo"},
        ],
    },
    {
        "codigo": "HUI",
        "nome": "Huíla",
        "capital": "Lubango",
        "regiao": "Sul",
        "latitude": -14.9172,
        "longitude": 13.4925,
        "municipios_principais": [
            "Lubango", "Humpata", "Chibia", "Matala", "Quipungo",
            "Caluquembe", "Cacula", "Quilengues", "Gambos", "Chicomba", "Jamba", "Chipindo", "Cuvango"
        ],
        "zonas_rapidas": [
            {"nome": "Lubango Centro", "lat": -14.9172, "lng": 13.4925, "ref": "Avenida Lúcio Lara / Sé Catedral"},
            {"nome": "Senhora do Monte / Mapunda", "lat": -14.9350, "lng": 13.4800, "ref": "Complexo da Senhora do Monte"},
            {"nome": "Humpata", "lat": -15.0060, "lng": 13.3650, "ref": "Planalto da Humpata"},
            {"nome": "Matala", "lat": -15.0280, "lng": 15.0340, "ref": "Barragem da Matala"},
        ],
    },
    {
        "codigo": "CAB",
        "nome": "Cabinda",
        "capital": "Cabinda",
        "regiao": "Norte (Enclave)",
        "latitude": -5.5500,
        "longitude": 12.2000,
        "municipios_principais": ["Cabinda", "Cacongo", "Buco-Zau", "Belize"],
        "zonas_rapidas": [
            {"nome": "Cabinda Centro", "lat": -5.5500, "lng": 12.2000, "ref": "Avenida Duque de Chiazi"},
            {"nome": "Futila / Malongo", "lat": -5.4600, "lng": 12.2200, "ref": "Polo Industrial e Petrolífero"},
            {"nome": "Cacongo (Lândana)", "lat": -5.2300, "lng": 12.1400, "ref": "Marginal de Lândana"},
        ],
    },
    {
        "codigo": "CUS",
        "nome": "Cuanza Sul",
        "capital": "Sumbe",
        "regiao": "Centro-Litoral",
        "latitude": -11.2061,
        "longitude": 13.8437,
        "municipios_principais": [
            "Sumbe", "Porto Amboim", "Amboim (Gabela)", "Cela (Waku Kungo)",
            "Libolo", "Quibala", "Seles", "Conda", "Cassongue", "Mussende", "Ebo", "Quilenda"
        ],
        "zonas_rapidas": [
            {"nome": "Sumbe Centro", "lat": -11.2061, "lng": 13.8437, "ref": "Marginal do Sumbe"},
            {"nome": "Porto Amboim", "lat": -10.7310, "lng": 13.7640, "ref": "Porto e Estaleiros"},
            {"nome": "Waku Kungo (Cela)", "lat": -11.3600, "lng": 15.1200, "ref": "Bacia Agrícola da Cela"},
        ],
    },
    {
        "codigo": "CUN",
        "nome": "Cuanza Norte",
        "capital": "N'dalatando",
        "regiao": "Centro-Norte",
        "latitude": -9.2978,
        "longitude": 14.9116,
        "municipios_principais": [
            "Cazengo (N'dalatando)", "Cambambe (Dondo)", "Golungo Alto",
            "Lucala", "Ambaca", "Quiculungo", "Bolongongo", "Banga", "Samba Caju", "Ngonguembo"
        ],
        "zonas_rapidas": [
            {"nome": "N'dalatando Centro", "lat": -9.2978, "lng": 14.9116, "ref": "Cazengo / Cidade Alta"},
            {"nome": "Dondo", "lat": -9.6940, "lng": 14.4280, "ref": "Barragem de Cambambe"},
        ],
    },
    {
        "codigo": "MAL",
        "nome": "Malanje",
        "capital": "Malanje",
        "regiao": "Norte",
        "latitude": -9.5402,
        "longitude": 16.3410,
        "municipios_principais": [
            "Malanje", "Calandula", "Cacuso", "Cangandala", "Kiwaba Nzoji",
            "Caculama", "Massango", "Marimba", "Quela", "Cambundi Catembo"
        ],
        "zonas_rapidas": [
            {"nome": "Malanje Centro", "lat": -9.5402, "lng": 16.3410, "ref": "Largo da Rainha Ginga"},
            {"nome": "Calandula", "lat": -9.1830, "lng": 15.9500, "ref": "Quedas de Calandula"},
            {"nome": "Cangandala", "lat": -9.7890, "lng": 16.4340, "ref": "Parque da Palanca Negra Gigante"},
        ],
    },
    {
        "codigo": "UIG",
        "nome": "Uíge",
        "capital": "Uíge",
        "regiao": "Norte",
        "latitude": -7.6086,
        "longitude": 15.0614,
        "municipios_principais": [
            "Uíge", "Negage", "Maquela do Zombo", "Damba", "Songo",
            "Bungo", "Ambuíla", "Bembe", "Puri", "Sanza Pombo", "Quitexe", "Cangola"
        ],
        "zonas_rapidas": [
            {"nome": "Uíge Centro", "lat": -7.6086, "lng": 15.0614, "ref": "Avenida dos Combatentes"},
            {"nome": "Negage", "lat": -7.7600, "lng": 15.2700, "ref": "Polo Agrícola do Negage"},
        ],
    },
    {
        "codigo": "ZAI",
        "nome": "Zaire",
        "capital": "Mbanza Kongo",
        "regiao": "Norte-Fronteiriço",
        "latitude": -6.2670,
        "longitude": 14.2401,
        "municipios_principais": ["Mbanza Kongo", "Soyo", "Nzeto", "Tomboco", "Cuimba", "Noqui"],
        "zonas_rapidas": [
            {"nome": "Soyo / Base do Kwanda", "lat": -6.1349, "lng": 12.3689, "ref": "Terminal Petrolífero do Kwanda"},
            {"nome": "Mbanza Kongo Centro", "lat": -6.2670, "lng": 14.2401, "ref": "Património Mundial da UNESCO / Kulumbimbi"},
            {"nome": "Nzeto", "lat": -7.2300, "lng": 12.8700, "ref": "Foz do Rio Mbridge"},
        ],
    },
    {
        "codigo": "NAM",
        "nome": "Namibe",
        "capital": "Moçâmedes",
        "regiao": "Sul-Litoral",
        "latitude": -15.1961,
        "longitude": 12.1522,
        "municipios_principais": ["Moçâmedes", "Tômbwa", "Virei", "Bibala", "Camucuio"],
        "zonas_rapidas": [
            {"nome": "Moçâmedes Centro", "lat": -15.1961, "lng": 12.1522, "ref": "Marginal de Moçâmedes / Praia das Miragens"},
            {"nome": "Tômbwa", "lat": -15.8030, "lng": 11.8340, "ref": "Porto Pesqueiro do Tômbwa"},
        ],
    },
    {
        "codigo": "BIE",
        "nome": "Bié",
        "capital": "Cuito",
        "regiao": "Planalto Central",
        "latitude": -12.3833,
        "longitude": 16.9333,
        "municipios_principais": [
            "Cuito", "Andulo", "Camacupa", "Catabola", "Chinguar",
            "Chitembo", "Cunhinga", "Cuemba", "Nharêa"
        ],
        "zonas_rapidas": [
            {"nome": "Cuito Centro", "lat": -12.3833, "lng": 16.9333, "ref": "Centro Urbano do Cuito"},
            {"nome": "Andulo", "lat": -11.4800, "lng": 16.7000, "ref": "Margem do Rio Nhia"},
        ],
    },
    {
        "codigo": "MOX",
        "nome": "Moxico",
        "capital": "Luena",
        "regiao": "Leste",
        "latitude": -11.7833,
        "longitude": 19.9167,
        "municipios_principais": [
            "Moxico (Luena)", "Luau", "Cameia (Lumeje)", "Camanongue",
            "Leua", "Alto Zambeze", "Bundas", "Luchazes"
        ],
        "zonas_rapidas": [
            {"nome": "Luena Centro", "lat": -11.7833, "lng": 19.9167, "ref": "Largo do Luena"},
            {"nome": "Luau (Fronteira RDC)", "lat": -10.7000, "lng": 22.2300, "ref": "Porto Seco do Luau / CFB"},
        ],
    },
    {
        "codigo": "LSU",
        "nome": "Lunda Sul",
        "capital": "Saurimo",
        "regiao": "Leste",
        "latitude": -9.6608,
        "longitude": 20.3916,
        "municipios_principais": ["Saurimo", "Muconda", "Dala", "Cacolo"],
        "zonas_rapidas": [
            {"nome": "Saurimo Centro", "lat": -9.6608, "lng": 20.3916, "ref": "Polo de Desenvolvimento Diamantífero"},
        ],
    },
    {
        "codigo": "LNO",
        "nome": "Lunda Norte",
        "capital": "Dundo",
        "regiao": "Leste",
        "latitude": -7.3800,
        "longitude": 20.8400,
        "municipios_principais": [
            "Chitato (Dundo)", "Cambulo", "Cuango", "Capenda Camulemba",
            "Lucapa", "Caungula", "Cuílo", "Lubalo", "Lóvua", "Xá Muteba"
        ],
        "zonas_rapidas": [
            {"nome": "Dundo Centro", "lat": -7.3800, "lng": 20.8400, "ref": "Centralidade do Dundo / Museu do Dundo"},
            {"nome": "Lucapa", "lat": -8.4200, "lng": 20.7400, "ref": "Zona Diamantífera de Lucapa"},
        ],
    },
    {
        "codigo": "CNN",
        "nome": "Cunene",
        "capital": "Ondjiva",
        "regiao": "Sul-Fronteiriço",
        "latitude": -17.0667,
        "longitude": 15.7333,
        "municipios_principais": ["Cuanhama (Ondjiva)", "Namacunde (Santa Clara)", "Ombadja", "Curoca", "Cahama", "Cuvelai"],
        "zonas_rapidas": [
            {"nome": "Ondjiva Centro", "lat": -17.0667, "lng": 15.7333, "ref": "Palácio do Governo / Centro Comercial"},
            {"nome": "Santa Clara (Fronteira Namíbia)", "lat": -17.3830, "lng": 15.9670, "ref": "Ponto Aduaneiro de Santa Clara"},
        ],
    },
    {
        "codigo": "CCU",
        "nome": "Cuando Cubango",
        "capital": "Menongue",
        "regiao": "Sudeste",
        "latitude": -14.6585,
        "longitude": 17.6910,
        "municipios_principais": [
            "Menongue", "Cuito Cuanavale", "Cuchi", "Calai",
            "Dirico", "Mavinga", "Rivungo", "Nancova", "Cuangar"
        ],
        "zonas_rapidas": [
            {"nome": "Menongue Centro", "lat": -14.6585, "lng": 17.6910, "ref": "Largo 1.º de Maio / Menongue"},
            {"nome": "Cuito Cuanavale", "lat": -15.1600, "lng": 19.1700, "ref": "Monumento da Batalha do Cuito Cuanavale"},
        ],
    },
    {
        "codigo": "BGO",
        "nome": "Bengo",
        "capital": "Caxito",
        "regiao": "Norte",
        "latitude": -8.5785,
        "longitude": 13.6644,
        "municipios_principais": ["Dande (Caxito)", "Ambriz", "Bula Atumba", "Dembos", "Nambuangongo", "Pango Aluquém"],
        "zonas_rapidas": [
            {"nome": "Caxito Centro", "lat": -8.5785, "lng": 13.6644, "ref": "Polo Açucareiro e Agrícola do Dande"},
            {"nome": "Ambriz", "lat": -7.8400, "lng": 13.1100, "ref": "Porto Histórico do Ambriz"},
        ],
    },
]


def calcular_distancia_haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calcula a distância geodésica em quilómetros entre dois pares de coordenadas."""
    raio_terra_km = 6371.0
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(d_lon / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return round(raio_terra_km * c, 2)


class AngolaProvinciasListView(APIView):
    """
    Endpoint: GET /api/v1/geo/provincias/
    Devolve a listagem oficial das 18 províncias de Angola com capitais,
    coordenadas geográficas WGS84 e número de estabelecimentos ativos.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        total_lojas = ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).count()

        resultado = []
        for prov in PROVINCIAS_ANGOLA:
            # Conta lojas que contenham o nome da província no endereço ou coordenadas
            nome_p = prov["nome"]
            lojas_prov = ParceiroLoja.objects.filter(
                morada_texto__icontains=nome_p,
                estado=ParceiroLoja.EstadoLoja.ATIVO,
            ).count()

            # Luanda é o hub principal garantido
            if prov["codigo"] == "LUA" and lojas_prov == 0:
                lojas_prov = total_lojas

            resultado.append({
                "codigo": prov["codigo"],
                "nome": prov["nome"],
                "capital": prov["capital"],
                "regiao": prov["regiao"],
                "latitude": prov["latitude"],
                "longitude": prov["longitude"],
                "total_municipios": len(prov["municipios_principais"]),
                "lojas_ativas_count": lojas_prov,
                "is_disponivel": True,
            })

        return Response(
            {
                "pais": "Angola",
                "codigo_iso": "AO",
                "moeda": "AOA (Kwanza - Kz)",
                "total_provincias": len(resultado),
                "provincias": resultado,
            },
            status=status.HTTP_200_OK,
        )


class AngolaMunicipiosListView(APIView):
    """
    Endpoint: GET /api/v1/geo/municipios/?provincia=LUA (ou nome)
    Devolve a listagem de municípios e zonas rápidas de entrega da província selecionada.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        filtro_prov = (request.query_params.get("provincia") or "LUA").strip().upper()

        prov_encontrada = None
        for p in PROVINCIAS_ANGOLA:
            if p["codigo"].upper() == filtro_prov or p["nome"].upper() == filtro_prov:
                prov_encontrada = p
                break

        if not prov_encontrada:
            prov_encontrada = PROVINCIAS_ANGOLA[0]  # Fallback Luanda

        return Response(
            {
                "provincia_codigo": prov_encontrada["codigo"],
                "provincia_nome": prov_encontrada["nome"],
                "capital": prov_encontrada["capital"],
                "latitude": prov_encontrada["latitude"],
                "longitude": prov_encontrada["longitude"],
                "municipios": prov_encontrada["municipios_principais"],
                "zonas_rapidas": prov_encontrada["zonas_rapidas"],
            },
            status=status.HTTP_200_OK,
        )


class AngolaGeoDetectView(APIView):
    """
    Endpoint: GET /api/v1/geo/detectar/?lat=-8.8368&lng=13.2343
    Recebe coordenadas GPS do utilizador e identifica automaticamente a província
    e o hub urbano angolano mais próximo, devolvendo a distância em km.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        try:
            lat = float(request.query_params.get("lat") or -8.8368)
            lng = float(request.query_params.get("lng") or 13.2343)
        except (ValueError, TypeError):
            lat, lng = -8.8368, 13.2343

        mais_proxima = None
        menor_distancia = float("inf")

        for prov in PROVINCIAS_ANGOLA:
            dist = calcular_distancia_haversine(lat, lng, prov["latitude"], prov["longitude"])
            if dist < menor_distancia:
                menor_distancia = dist
                mais_proxima = prov

        hub_mais_proximo = None
        menor_dist_hub = float("inf")
        if mais_proxima:
            for zona in mais_proxima.get("zonas_rapidas", []):
                dist_z = calcular_distancia_haversine(lat, lng, zona["lat"], zona["lng"])
                if dist_z < menor_dist_hub:
                    menor_dist_hub = dist_z
                    hub_mais_proximo = zona

        return Response(
            {
                "coordenadas_informadas": {"latitude": lat, "longitude": lng},
                "provincia_detectada": {
                    "codigo": mais_proxima["codigo"],
                    "nome": mais_proxima["nome"],
                    "capital": mais_proxima["capital"],
                    "distancia_capital_km": menor_distancia,
                },
                "hub_mais_proximo": hub_mais_proximo,
                "distancia_hub_km": menor_dist_hub if menor_dist_hub != float("inf") else menor_distancia,
            },
            status=status.HTTP_200_OK,
        )
