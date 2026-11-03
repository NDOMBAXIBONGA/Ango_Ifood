"""
Rotas da aplicação 'accounts' para autenticação passwordless via OTP e conclusão de registo.
"""
from django.urls import path

from apps.accounts.views import (
    CompleteRegistrationView,
    EmailRegisterView,
    EmailRequestOTPView,
    EmailVerifyOTPView,
    GoogleAuthView,
    RequestOTPView,
    VerifyOTPView,
)

app_name = "accounts"

urlpatterns = [
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
