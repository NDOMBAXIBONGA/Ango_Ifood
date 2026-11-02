"""
Sinais Django personalizados para o ciclo de vida e transições de estado do OMS ('orders').
Implementa a Secção 5.1 e 6.7, permitindo que outros subsistemas (Logística, Notificações,
Financeiro/Ledger e Suporte) reajam de forma desacoplada aos eventos do pedido.
"""
from django.dispatch import Signal

# Disparado genericamente em qualquer transição de estado bem-sucedida
# Fornece: pedido, estado_anterior, novo_estado, evento, ator, dados_adicionais
order_state_transitioned = Signal()

# Disparado ao transitar para 'AGUARDA_PARCEIRO': inicia o timer de timeout de aceitação (RN-070)
order_awaiting_partner = Signal()

# Disparado ao transitar para 'ACEITE': inicia o motor de despacho logístico (Secção 8, RN-090)
order_accepted = Signal()

# Disparado ao transitar para 'EM_PREPARACAO': atualiza previsões e notifica o cliente
order_in_preparation = Signal()

# Disparado ao transitar para 'PRONTO': notifica o estafeta atribuído para recolha ao balcão
order_ready_for_pickup = Signal()

# Disparado ao transitar para 'RECOLHIDO': notifica o cliente que o estafeta recolheu o pedido
order_picked_up = Signal()

# Disparado ao transitar para 'EM_TRANSITO': ativa rastreio em tempo real e atualização de ETA
order_in_transit = Signal()

# Disparado ao transitar para 'ENTREGUE': confirmação de entrega via PIN e prova GPS (RN-095)
order_delivered = Signal()

# Disparado ao transitar para 'CONCLUIDO': desencadeia liquidação no Livro Razão Ledger (Secção 7.3, RN-150)
order_completed = Signal()

# Disparado em saídas excecionais (CANCELADO, REJEITADO, FALHA_ENTREGA, REEMBOLSADO)
order_cancelled = Signal()
order_rejected = Signal()
order_delivery_failed = Signal()
order_refunded = Signal()

# Disparado ao receber coordenadas de GPS do estafeta em tempo real (RN-094, Secção 12.1)
# Fornece: estafeta_id, pedido_id, latitude, longitude, heading, speed, timestamp
estafeta_location_updated = Signal()

