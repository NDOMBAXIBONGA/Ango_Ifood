"""
Rotas da aplicação 'accounts' para autenticação passwordless via OTP e conclusão de registo.
"""
from django.urls import path

from apps.accounts.views import (
    CompleteRegistrationView,
    RequestOTPView,
    VerifyOTPView,
)

app_name = "accounts"

urlpatterns = [
    path("request-otp/", RequestOTPView.as_view(), name="request_otp"),
    path("verify-otp/", VerifyOTPView.as_view(), name="verify_otp"),
    path("complete-registration/", CompleteRegistrationView.as_view(), name="complete_registration"),
]
