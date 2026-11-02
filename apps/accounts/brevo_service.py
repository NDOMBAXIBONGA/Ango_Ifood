"""
Serviço de Integração com a API de E-mails Transacionais da Brevo (antigo Sendinblue).
Módulo isolado para emissão segura de códigos únicos (OTP) de autenticação e validação de contas.
"""
from __future__ import annotations

import logging
import os
from typing import Any

import requests
from django.conf import settings

logger = logging.getLogger(__name__)


class BrevoEmailService:
    """
    Classe utilitária e de serviço isolada para envio de e-mails transacionais via API v3 da Brevo.
    Utilizada principalmente no fluxo passwordless para envio de OTPs de validação e criação de conta.
    """

    # Endpoint oficial da API v3 da Brevo para envio de e-mails transacionais (SMTP)
    DEFAULT_API_URL = "https://api.brevo.com/v3/smtp/email"
    DEFAULT_SENDER_NAME = "Delivery Pro"
    DEFAULT_SENDER_EMAIL = "no-reply@deliverypro.ao"
    DEFAULT_TIMEOUT_SECONDS = 15

    def __init__(self, api_key: str | None = None, api_url: str | None = None) -> None:
        """
        Inicializa o serviço carregando a chave de API e configurações de remetente
        de forma segura a partir das variáveis de ambiente ou das configurações do Django.
        """
        self.api_key: str = (
            api_key
            or os.environ.get("BREVO_API_KEY")
            or getattr(settings, "BREVO_API_KEY", "")
        )

        self.api_url: str = (
            api_url
            or os.environ.get("BREVO_API_URL")
            or getattr(settings, "BREVO_API_URL", self.DEFAULT_API_URL)
        )

        self.sender_name: str = (
            os.environ.get("BREVO_SENDER_NAME")
            or getattr(settings, "BREVO_SENDER_NAME", self.DEFAULT_SENDER_NAME)
        )

        self.sender_email: str = (
            os.environ.get("BREVO_SENDER_EMAIL")
            or getattr(settings, "BREVO_SENDER_EMAIL", None)
            or getattr(settings, "DEFAULT_FROM_EMAIL", self.DEFAULT_SENDER_EMAIL)
        )

        if not self.api_key:
            logger.warning(
                "BrevoEmailService inicializado sem 'BREVO_API_KEY'. "
                "O envio de e-mails falhará se a variável de ambiente não for configurada."
            )

    def _gerar_html_template_otp(self, codigo_otp: str) -> str:
        """
        Gera um template HTML minimalista, moderno e 100% responsivo em português de Angola.
        Destaca visualmente o código de 6 dígitos e apresenta as advertências legais de expiração e segurança.
        """
        return f"""<!DOCTYPE html>
<html lang="pt-AO">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Seu Código de Confirmação - Delivery Pro</title>
    <style>
        body {{
            margin: 0;
            padding: 0;
            background-color: #F8FAFC;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            color: #0F172A;
            line-height: 1.6;
        }}
        .email-wrapper {{
            max-width: 580px;
            margin: 40px auto;
            background-color: #FFFFFF;
            border-radius: 16px;
            overflow: hidden;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05), 0 2px 4px -2px rgba(0, 0, 0, 0.05);
            border: 1px solid #E2E8F0;
        }}
        .header {{
            background: linear-gradient(135deg, #DC2626 0%, #B91C1C 100%);
            padding: 32px 24px;
            text-align: center;
        }}
        .header h1 {{
            margin: 0;
            color: #FFFFFF;
            font-size: 24px;
            font-weight: 800;
            letter-spacing: 1px;
            text-transform: uppercase;
        }}
        .header p {{
            margin: 6px 0 0 0;
            color: #FEE2E2;
            font-size: 13px;
            font-weight: 500;
        }}
        .content {{
            padding: 36px 32px;
            text-align: center;
        }}
        .content h2 {{
            margin: 0 0 12px 0;
            font-size: 20px;
            font-weight: 700;
            color: #0F172A;
        }}
        .content p {{
            margin: 0 0 24px 0;
            font-size: 15px;
            color: #475569;
        }}
        .otp-container {{
            background-color: #FEF2F2;
            border: 2px dashed #FCA5A5;
            border-radius: 12px;
            padding: 20px;
            margin: 28px 0;
            display: inline-block;
            min-width: 220px;
        }}
        .otp-code {{
            font-size: 36px;
            font-weight: 800;
            letter-spacing: 10px;
            color: #DC2626;
            font-family: 'Courier New', Courier, monospace;
            margin: 0;
        }}
        .alert-box {{
            background-color: #FFFBEB;
            border-left: 4px solid #F59E0B;
            padding: 14px 18px;
            border-radius: 8px;
            text-align: left;
            margin-top: 24px;
        }}
        .alert-box p {{
            margin: 0;
            font-size: 13px;
            color: #92400E;
            line-height: 1.5;
        }}
        .footer {{
            background-color: #F1F5F9;
            padding: 24px 32px;
            text-align: center;
            border-top: 1px solid #E2E8F0;
        }}
        .footer p {{
            margin: 4px 0;
            font-size: 12px;
            color: #64748B;
        }}
    </style>
</head>
<body>
    <div class="email-wrapper">
        <div class="header">
            <h1>DELIVERY PRO</h1>
            <p>Plataforma de Entregas de Angola</p>
        </div>
        <div class="content">
            <h2>Validação de Segurança</h2>
            <p>Utilize o código de verificação abaixo para confirmar a sua identidade e continuar o acesso à sua conta.</p>
            
            <div class="otp-container">
                <div class="otp-code">{codigo_otp}</div>
            </div>

            <div class="alert-box">
                <p><strong>Aviso Importante:</strong> Este código expira em <strong>5 minutos</strong>. Se não solicitou esta validação, por favor ignore esta mensagem. Nunca partilhe este código com terceiros.</p>
            </div>
        </div>
        <div class="footer">
            <p>&copy; 2026 Delivery Pro Angola. Todos os direitos reservados.</p>
            <p>Este é um e-mail transacional gerado automaticamente. Por favor, não responda a esta mensagem.</p>
        </div>
    </div>
</body>
</html>"""

    def enviar_email_otp(self, email_destino: str, codigo_otp: str) -> bool:
        """
        Envia o e-mail transacional contendo o código OTP de 6 dígitos via API da Brevo.

        Args:
            email_destino: Endereço de e-mail do utilizador destinatário.
            codigo_otp: Código numérico de 6 dígitos gerado pelo sistema.

        Returns:
            bool: True se o e-mail foi aceite e enfileirado com sucesso pela Brevo (HTTP 200, 201 ou 202);
                  False em caso de erro de conexão, validação, credenciais inválidas ou timeout.
        """
        sanitized_email = email_destino.strip().lower() if email_destino else ""

        if not sanitized_email or not codigo_otp:
            logger.error(
                "Falha ao enviar e-mail OTP: 'email_destino' ou 'codigo_otp' ausente. "
                "Destino: '%s' | OTP: '%s'",
                sanitized_email,
                codigo_otp,
            )
            return False

        if not self.api_key:
            logger.critical(
                "Falha de configuração: 'BREVO_API_KEY' não está definida nas variáveis de ambiente. "
                "Impossível disparar e-mail OTP para %s.",
                sanitized_email,
            )
            return False

        headers: dict[str, str] = {
            "api-key": self.api_key,
            "content-type": "application/json",
            "accept": "application/json",
        }

        payload: dict[str, Any] = {
            "sender": {
                "name": self.sender_name,
                "email": self.sender_email,
            },
            "to": [
                {
                    "email": sanitized_email,
                }
            ],
            "subject": "Seu Código de Confirmação - Delivery Pro",
            "htmlContent": self._gerar_html_template_otp(codigo_otp),
        }

        try:
            logger.info(
                "A disparar e-mail OTP via Brevo para: %s | Remetente: %s <%s>",
                sanitized_email,
                self.sender_name,
                self.sender_email,
            )

            response = requests.post(
                self.api_url,
                json=payload,
                headers=headers,
                timeout=self.DEFAULT_TIMEOUT_SECONDS,
            )

            # A Brevo retorna HTTP 201 Created quando o e-mail é enfileirado/enviado com sucesso
            if response.status_code in (200, 201, 202):
                resposta_data = {}
                try:
                    resposta_data = response.json()
                except Exception:
                    pass

                message_id = resposta_data.get("messageId", "desconhecido")
                logger.info(
                    "E-mail OTP enviado com sucesso via Brevo para %s (Status: %s | MessageID: %s).",
                    sanitized_email,
                    response.status_code,
                    message_id,
                )
                return True

            logger.error(
                "A API da Brevo rejeitou o envio do e-mail para %s. "
                "Código de resposta HTTP: %s | Detalhes: %s",
                sanitized_email,
                response.status_code,
                response.text,
            )
            return False

        except requests.exceptions.Timeout as e:
            logger.error(
                "Timeout ao comunicar com a API da Brevo ao enviar OTP para %s após %ds: %s",
                sanitized_email,
                self.DEFAULT_TIMEOUT_SECONDS,
                str(e),
                exc_info=True,
            )
            return False

        except requests.exceptions.ConnectionError as e:
            logger.error(
                "Erro de conexão de rede ao comunicar com a Brevo para %s: %s",
                sanitized_email,
                str(e),
                exc_info=True,
            )
            return False

        except requests.exceptions.RequestException as e:
            logger.error(
                "Exceção genérica de requisição HTTP na API da Brevo para %s: %s",
                sanitized_email,
                str(e),
                exc_info=True,
            )
            return False

        except Exception as e:
            logger.critical(
                "Erro inesperado no serviço BrevoEmailService ao enviar OTP para %s: %s",
                sanitized_email,
                str(e),
                exc_info=True,
            )
            return False

