"""
Shim de compatibilidade do GeoDjango / GDAL para ambiente Windows.
Permite executar 'python manage.py createsuperuser', 'migrate', 'runserver' e testes
em máquinas Windows sem necessidade de instalar pacotes complexos do OSGeo4W/C++.
Em produção (Linux/Docker/Render), este shim é ignorado e o GDAL nativo é utilizado.
"""
import os
import sys
import types
from ctypes import CFUNCTYPE, c_char_p, c_int


def ensure_gdal_compatibility() -> None:
    """Garante que comandos de gestão Django funcionam no Windows sem falhas em GDAL/GEOS."""
    if os.name != "nt":
        return

    # 1. Adiciona diretórios de bibliotecas do venv (como shapely.libs) ao caminho de DLLs do Windows
    try:
        from pathlib import Path
        base_dir = Path(__file__).resolve().parent.parent
        possible_dll_dirs = [
            base_dir / "venv" / "Lib" / "site-packages" / "shapely.libs",
            base_dir / "venv" / "Lib" / "site-packages" / "numpy.libs",
            base_dir / "venv" / "Lib" / "site-packages" / "psycopg2_binary.libs",
        ]
        for d in possible_dll_dirs:
            if d.exists():
                dll_str = str(d)
                if hasattr(os, "add_dll_directory"):
                    try:
                        os.add_dll_directory(dll_str)
                    except Exception:
                        pass
                os.environ["PATH"] = dll_str + os.pathsep + os.environ.get("PATH", "")
    except Exception:
        pass

    # 2. Se o GDAL já foi importado, não reconfigura
    if "django.contrib.gis.gdal.libgdal" in sys.modules:
        return

    # Tenta verificar se o GDAL nativo já existe e carrega normalmente
    try:
        from django.contrib.gis.gdal import libgdal  # noqa
        return  # GDAL nativo funcional
    except Exception:
        pass  # GDAL ausente no Windows; injeta shim de segurança

    class MockCDLLFunction:
        def __init__(self, name: str):
            self.__name__ = name
            self.argtypes = []
            self.restype = None

        def __call__(self, *args, **kwargs):
            if self.__name__ == "GDALVersionInfo":
                return b"3.8.0"
            return 0

    class MockCDLL:
        def __init__(self):
            self._funcs = {}

        def __getattr__(self, name: str):
            if name not in self._funcs:
                self._funcs[name] = MockCDLLFunction(name)
            return self._funcs[name]

        def __getitem__(self, name: str):
            return self.__getattr__(name)

    mock_mod = types.ModuleType("django.contrib.gis.gdal.libgdal")
    mock_mod.lgdal = MockCDLL()
    mock_mod.lwingdal = MockCDLL()

    def std_call(func: str):
        return mock_mod.lgdal[func]

    mock_mod.std_call = std_call
    mock_mod._version_info = mock_mod.lgdal["GDALVersionInfo"]
    mock_mod.gdal_version = lambda: b"3.8.0"
    mock_mod.gdal_full_version = lambda: b"GDAL 3.8.0"
    mock_mod.gdal_version_info = lambda: (3, 8, 0)
    mock_mod.GDAL_VERSION = (3, 8, 0)

    cpl_handler_type = CFUNCTYPE(None, c_int, c_int, c_char_p)
    mock_mod.CPLErrorHandler = cpl_handler_type
    mock_mod.err_handler = cpl_handler_type(lambda *a: None)

    def function(name: str, args, restype):
        f = std_call(name)
        f.argtypes = args
        f.restype = restype
        return f

    mock_mod.function = function
    mock_mod.set_error_handler = function("CPLSetErrorHandler", [cpl_handler_type], cpl_handler_type)

    sys.modules["django.contrib.gis.gdal.libgdal"] = mock_mod
