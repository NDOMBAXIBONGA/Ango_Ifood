"""
Rotas para a API de Cobertura Geográfica de Angola (/api/v1/geo/).
"""
from django.urls import path

from apps.catalog.geo_views import (
    AngolaGeoDetectView,
    AngolaMunicipiosListView,
    AngolaProvinciasListView,
)

app_name = "geo"

urlpatterns = [
    # GET /api/v1/geo/provincias/ - Lista oficial das 18 províncias de Angola
    path("provincias/", AngolaProvinciasListView.as_view(), name="provincias-list"),
    # GET /api/v1/geo/municipios/ - Municípios e zonas rápidas da província (?provincia=LUA ou nome)
    path("municipios/", AngolaMunicipiosListView.as_view(), name="municipios-list"),
    # GET /api/v1/geo/detectar/ - Deteção automática por GPS da província e hub mais próximo (?lat=...&lng=...)
    path("detectar/", AngolaGeoDetectView.as_view(), name="geo-detect"),
]
