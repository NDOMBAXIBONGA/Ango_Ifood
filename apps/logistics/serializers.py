"""
Serializers da aplicação 'logistics' para encerramento seguro e verificação de PIN de entrega.
Implementa as regras RN-093, RN-095, RN-096 e RN-097.
"""
from rest_framework import serializers


class DeliveryVerifyPinInputSerializer(serializers.Serializer):
    """
    RN-095: Input para validação do PIN de entrega de 4 dígitos digitado pelo estafeta.
    """
    pedido_id = serializers.UUIDField(
        required=True,
        help_text="UUID do pedido cuja entrega está a ser encerrada.",
    )
    pin_introduzido = serializers.CharField(
        max_length=4,
        min_length=4,
        required=True,
        help_text="Código numérico de 4 dígitos fornecido pelo cliente presencialmente.",
    )
    latitude = serializers.FloatField(
        required=False,
        min_value=-90.0,
        max_value=90.0,
        help_text="Latitude GPS no momento da confirmação para registo de prova PostGIS (RN-095).",
    )
    longitude = serializers.FloatField(
        required=False,
        min_value=-180.0,
        max_value=180.0,
        help_text="Longitude GPS no momento da confirmação para registo de prova PostGIS (RN-095).",
    )
    prova_foto_url = serializers.URLField(
        required=False,
        allow_blank=True,
        help_text="URL da fotografia de prova de entrega caso aplicável.",
    )

    def validate_pin_introduzido(self, value: str) -> str:
        value = value.strip()
        if not value.isdigit() or len(value) != 4:
            raise serializers.ValidationError("O PIN de entrega tem de conter exatamente 4 dígitos numéricos.")
        return value


class DeliveryReportAbsenceInputSerializer(serializers.Serializer):
    """
    RN-096 / RN-097: Input para reporte de ausência do cliente após cumprimento da
    tolerância obrigatória de espera de 7 minutos (420 segundos) no local.
    """
    pedido_id = serializers.UUIDField(
        required=True,
        help_text="UUID do pedido no qual o cliente não compareceu.",
    )
    latitude = serializers.FloatField(
        required=True,
        min_value=-90.0,
        max_value=90.0,
        help_text="Latitude GPS no local de entrega comprovando presença física (RN-096).",
    )
    longitude = serializers.FloatField(
        required=True,
        min_value=-180.0,
        max_value=180.0,
        help_text="Longitude GPS no local de entrega comprovando presença física (RN-096).",
    )
    tentativas_contacto = serializers.IntegerField(
        required=False,
        default=2,
        min_value=1,
        help_text="Número de tentativas de contacto telefónico efetuadas pelo estafeta sem sucesso.",
    )
    motivo = serializers.CharField(
        required=False,
        default="Cliente ausente após 7 minutos de espera regulamentar sem atender chamadas.",
        max_length=255,
        help_text="Justificação detalhada do encerramento por ausência.",
    )
    prova_foto_url = serializers.URLField(
        required=False,
        allow_blank=True,
        help_text="Fotografia da fachada/campainha do edifício como prova de presença.",
    )


class DeliveryArrivalInputSerializer(serializers.Serializer):
    """
    RN-096: Input para registar a chegada do estafeta ao endereço do cliente,
    iniciando o cronómetro regressivo oficial de tolerância de 7 minutos.
    """
    pedido_id = serializers.UUIDField(required=True)
    latitude = serializers.FloatField(required=False, min_value=-90.0, max_value=90.0)
    longitude = serializers.FloatField(required=False, min_value=-180.0, max_value=180.0)
