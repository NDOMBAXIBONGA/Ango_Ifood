"""
Backend de autenticação flexível para a plataforma Delivery Pro.
Permite autenticação com número de telemóvel (formato E.164) OU endereço de e-mail.
Compatível com o Django Admin (/admin/) e a API REST.
"""
from django.contrib.auth.backends import ModelBackend
from django.db.models import Q
from apps.accounts.models import CustomUser


class EmailOrPhoneBackend(ModelBackend):
    """
    Permite autenticação por telemóvel ou e-mail tanto no Django Admin quanto nas APIs.
    """

    def authenticate(self, request, username=None, password=None, **kwargs):
        if username is None:
            username = kwargs.get("email") or kwargs.get("telemovel")

        if not username or not password:
            return None

        identificador = str(username).strip()

        try:
            # Tenta localizar o utilizador por telemóvel ou e-mail (case-insensitive)
            user = CustomUser.objects.filter(
                Q(telemovel__iexact=identificador) | Q(email__iexact=identificador)
            ).first()

            if user and user.check_password(password) and self.user_can_authenticate(user):
                return user
        except Exception:
            return None

        return None
