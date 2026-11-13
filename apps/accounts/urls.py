"""
Rotas da aplicação 'accounts' para autenticação passwordless via OTP e conclusão de registo.
"""
from django.urls import path

from apps.accounts.views import (
    ChangePasswordView,
    CompleteRegistrationView,
    CustomerProfileView,
    EmailPasswordLoginView,
    EmailRegisterView,
    EmailRequestOTPView,
    EmailVerifyOTPView,
    GoogleAuthView,
    MoradaViewSet,
    RequestOTPView,
    VerifyOTPView,
)

app_name = "accounts"

moradas_list = MoradaViewSet.as_view({"get": "list", "post": "create"})
moradas_detail = MoradaViewSet.as_view(
    {"get": "retrieve", "delete": "destroy", "put": "update", "patch": "partial_update"}
)

urlpatterns = [
    # Gestão de Perfil e Segurança do Utilizador
    path("profile/", CustomerProfileView.as_view(), name="customer-profile"),
    path("change-password/", ChangePasswordView.as_view(), name="change-password"),
    # Gestão de Moradas do Utilizador (RN-005)
    path("moradas/", moradas_list, name="moradas-list"),
    path("moradas/<uuid:pk>/", moradas_detail, name="moradas-detail"),
    # Autenticação Direta com E-mail/Telemóvel e Palavra-passe
    path("login/", EmailPasswordLoginView.as_view(), name="login"),
    path("email/login/", EmailPasswordLoginView.as_view(), name="email_login_alias"),

    # Fluxo Passwordless por Telemóvel / SMS
    path("request-otp/", RequestOTPView.as_view(), name="request_otp"),
    path("verify-otp/", VerifyOTPView.as_view(), name="verify_otp"),
    path("complete-registration/", CompleteRegistrationView.as_view(), name="complete_registration"),

    # Fluxo Dedicado de Autenticação e Registo por E-mail (Brevo Transactional)
    path("email/request/", EmailRequestOTPView.as_view(), name="email_request_otp"),
    path("request-email-otp/", EmailRequestOTPView.as_view(), name="request_email_otp_alias"),
    path("email/verify/", EmailVerifyOTPView.as_view(), name="email_verify_otp"),
    path("verify-email-otp/", EmailVerifyOTPView.as_view(), name="verify_email_otp_alias"),
    path("email/register/", EmailRegisterView.as_view(), name="email_register"),

    # Autenticação Social via Google Sign-In (ID Token)
    path("google/", GoogleAuthView.as_view(), name="google_auth"),
    path("google-login/", GoogleAuthView.as_view(), name="google_auth_alias"),
]
