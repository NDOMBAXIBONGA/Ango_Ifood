"""
Configuração de rotas (URLconf) da aplicação 'cart'.
Disponibiliza os endpoints REST:
- GET  /api/v1/cart/
- DELETE /api/v1/cart/
- POST /api/v1/cart/clear/
- GET  /api/v1/cart/items/
- POST /api/v1/cart/items/
- PATCH /api/v1/cart/items/<item_id>/
- DELETE /api/v1/cart/items/<item_id>/remove/
- POST /api/v1/cart/items/substitute-preference/
"""
from django.urls import path

from apps.cart.views import CartViewSet

app_name = "cart"

cart_list = CartViewSet.as_view({"get": "list", "delete": "clear"})
cart_items = CartViewSet.as_view({"get": "list", "post": "add_item"})
cart_item_detail = CartViewSet.as_view({"patch": "update_quantity", "delete": "remove_item"})
cart_substitute = CartViewSet.as_view({"post": "substitute_preference"})
cart_clear = CartViewSet.as_view({"post": "clear", "delete": "clear"})

urlpatterns = [
    path("", cart_list, name="cart-root"),
    path("clear/", cart_clear, name="cart-clear"),
    path("items/", cart_items, name="cart-items"),
    path("items/substitute-preference/", cart_substitute, name="cart-substitute-preference"),
    path("items/<uuid:item_id>/", cart_item_detail, name="cart-item-detail"),
    path("items/<uuid:item_id>/remove/", cart_item_detail, name="cart-item-remove"),
]

