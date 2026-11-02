"""
Testes unitários e de integração para o fluxo de autenticação passwordless OTP (RN-001 a RN-008).
Valida os 3 endpoints de segurança:
1. POST `/api/v1/auth/request-otp/`
2. POST `/api/v1/auth/verify-otp/`
3. POST `/api/v1/auth/complete-registration/`
"""
from datetime import date, timedelta

from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.accounts.models import CustomUser, PerfilConsentimento, RegistoOTP


class PasswordlessOTPAuthTests(TestCase):
    def setUp(self) -> None:
        self.client = APIClient()
        self.telemovel_cliente = "+244923111222"
        self.telemovel_novo = "+244933444555"

        self.url_request_otp = reverse("accounts:request_otp")
        self.url_verify_otp = reverse("accounts:verify_otp")
        self.url_complete_reg = reverse("accounts:complete_registration")

    def test_request_otp_sucesso(self) -> None:
        """RN-001 / RN-002: Solicitação válida de OTP gera código de 6 dígitos com TTL de 5 min."""
        payload = {"telemovel": self.telemovel_cliente}
        response = self.client.post(self.url_request_otp, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("expira_em", response.data)
        self.assertEqual(response.data["validade_minutos"], 5)
        self.assertEqual(response.data["tentativas_permitidas"], 5)

        # Verifica registo na base de dados
        registo = RegistoOTP.objects.filter(telemovel=self.telemovel_cliente).first()
        self.assertIsNotNone(registo)
        self.assertEqual(len(registo.codigo_otp), 6)
        self.assertEqual(registo.tentativas_restantes, 5)
        self.assertEqual(registo.contagem_envios_hora, 1)

    def test_request_otp_limite_3_envios_por_hora_rn002(self) -> None:
        """RN-002: O 4.º envio na mesma hora deve retornar HTTP 429 Too Many Requests."""
        payload = {"telemovel": self.telemovel_cliente}

        # 1.º, 2.º e 3.º envios devem passar
        for _ in range(3):
            res = self.client.post(self.url_request_otp, payload, format="json")
            self.assertEqual(res.status_code, status.HTTP_200_OK)

        # 4.º envio deve ser barrado com 429
        res_quarto = self.client.post(self.url_request_otp, payload, format="json")
        self.assertEqual(res_quarto.status_code, status.HTTP_429_TOO_MANY_REQUESTS)
        self.assertEqual(res_quarto.data["erro"], "limite_envios_excedido")

    def test_request_otp_conta_suspensa_bloqueada_rn008(self) -> None:
        """RN-008: Utilizador com estado SUSPENSO não pode solicitar OTP (HTTP 403 Forbidden)."""
        CustomUser.objects.create_user(
            telemovel=self.telemovel_cliente,
            email="suspenso@test.com",
            nome="Utilizador Suspenso",
            estado=CustomUser.EstadoConta.SUSPENSO,
        )

        payload = {"telemovel": self.telemovel_cliente}
        response = self.client.post(self.url_request_otp, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["erro"], "conta_suspensa")

    def test_verify_otp_expirado_falha(self) -> None:
        """RN-002: Código expirado após 5 minutos deve retornar HTTP 400 Bad Request."""
        agora = timezone.now()
        RegistoOTP.objects.create(
            telemovel=self.telemovel_cliente,
            codigo_otp="123456",
            tentativas_restantes=5,
            expira_em=agora - timedelta(seconds=1),  # Expirado!
        )

        payload = {"telemovel": self.telemovel_cliente, "codigo_otp": "123456"}
        response = self.client.post(self.url_verify_otp, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["erro"], "otp_expirado")

    def test_verify_otp_incorreto_decrementa_e_bloqueia_15min_rn002(self) -> None:
        """RN-002: Código incorreto decrementa tentativas; ao atingir 0 bloqueia por 15 min."""
        agora = timezone.now()
        RegistoOTP.objects.create(
            telemovel=self.telemovel_cliente,
            codigo_otp="999999",
            tentativas_restantes=1,  # Apenas 1 restante
            expira_em=agora + timedelta(minutes=5),
        )

        payload = {"telemovel": self.telemovel_cliente, "codigo_otp": "000000"}
        response = self.client.post(self.url_verify_otp, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["erro"], "tentativas_esgotadas")
        self.assertIn("bloqueado_ate", response.data)

        registo = RegistoOTP.objects.get(telemovel=self.telemovel_cliente)
        self.assertEqual(registo.tentativas_restantes, 0)
        self.assertIsNotNone(registo.bloqueado_ate)

    def test_verify_otp_sucesso_conta_existente_emite_jwt(self) -> None:
        """RN-006: Utilizador existente autentica e recebe tokens JWT de Access e Refresh."""
        user = CustomUser.objects.create_user(
            telemovel=self.telemovel_cliente,
            email="existente@test.com",
            nome="Utilizador Existente",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        agora = timezone.now()
        RegistoOTP.objects.create(
            telemovel=self.telemovel_cliente,
            codigo_otp="654321",
            tentativas_restantes=5,
            expira_em=agora + timedelta(minutes=5),
        )

        payload = {"telemovel": self.telemovel_cliente, "codigo_otp": "654321"}
        response = self.client.post(self.url_verify_otp, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["registo_pendente"])
        self.assertIn("access", response.data["tokens"])
        self.assertIn("refresh", response.data["tokens"])
        self.assertEqual(response.data["perfil"]["nome"], user.nome)

    def test_verify_otp_sucesso_conta_nova_redireciona(self) -> None:
        """RN-002: Novo número validado devolve flag de registo pendente para redirecionamento."""
        agora = timezone.now()
        RegistoOTP.objects.create(
            telemovel=self.telemovel_novo,
            codigo_otp="112233",
            tentativas_restantes=5,
            expira_em=agora + timedelta(minutes=5),
        )

        payload = {"telemovel": self.telemovel_novo, "codigo_otp": "112233"}
        response = self.client.post(self.url_verify_otp, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["registo_pendente"])
        self.assertTrue(response.data["requires_registration_completion"])
        self.assertEqual(response.data["telemovel"], self.telemovel_novo)

    def test_complete_registration_menor_idade_rejeitado_rn003(self) -> None:
        """RN-003: Menor de 18 anos civis é rejeitado com HTTP 400 Bad Request."""
        hoje = timezone.localdate()
        # Menor de 17 anos
        data_menor = hoje - timedelta(days=17 * 365)

        payload = {
            "telemovel": self.telemovel_novo,
            "nome": "Candidato Menor",
            "email": "menor@test.com",
            "data_nascimento": str(data_menor),
        }
        response = self.client.post(self.url_complete_reg, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("data_nascimento", response.data)

    def test_complete_registration_sucesso_maior_idade_rn003_rn004(self) -> None:
        """RN-003 / RN-004 / RN-006: Utilizador maior de idade cria conta, ativa consentimentos e recebe JWT."""
        hoje = timezone.localdate()
        # Maior de 20 anos
        data_maior = hoje - timedelta(days=20 * 365)

        payload = {
            "telemovel": self.telemovel_novo,
            "nome": "Candidato Adulto",
            "email": "adulto@test.com",
            "data_nascimento": str(data_maior),
        }
        response = self.client.post(self.url_complete_reg, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertFalse(response.data["registo_pendente"])
        self.assertIn("access", response.data["tokens"])
        self.assertIn("refresh", response.data["tokens"])
        self.assertEqual(response.data["perfil"]["nome"], "Candidato Adulto")

        # Verifica persistência no CustomUser e PerfilConsentimento
        user = CustomUser.objects.get(telemovel=self.telemovel_novo)
        self.assertEqual(user.estado, CustomUser.EstadoConta.ATIVO)
        self.assertTrue(user.is_active)

        consentimento = PerfilConsentimento.objects.get(utilizador=user)
        self.assertTrue(consentimento.termos_utilizacao)
        self.assertTrue(consentimento.politica_privacidade)

